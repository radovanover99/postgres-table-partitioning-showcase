-- =====================================================================
-- 05_archive_toolkit.sql
-- The archive target and the DDL generator that moves cold partitions
-- into it.
--
-- THE STRATEGY IN ONE PARAGRAPH
-- Hot data lives in core.wallet_ledger. Once a partition's entire range
-- is older than the 90-day window, we DETACH it (concurrently, so the
-- ledger keeps taking writes), move it to the archive schema, and
-- ATTACH it to a second partitioned table, archive.wallet_ledger. No
-- rows are copied, no rows are deleted, no bloat is created. The data
-- is still ordinary Postgres data — still queryable, still backed up,
-- just out of the way of the transactional workload.
--
-- WHY A GENERATOR INSTEAD OF A PROCEDURE
-- ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY cannot run inside a
-- transaction block, and a PL/pgSQL function or procedure is ALWAYS
-- inside one:
--     ERROR:  ALTER TABLE ... DETACH CONCURRENTLY cannot be executed
--             from a function
-- So the toolkit generates the statements and you execute them with
-- psql's \gexec (or from scripts/archive.sh). As a bonus you can read
-- the plan before you run it, which is a nice property for a job that
-- touches the ledger.
-- =====================================================================
\set ON_ERROR_STOP on
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- The archive parent.
--
-- LIKE (with no INCLUDING clauses) copies column names, types and NOT
-- NULL and nothing else. That is deliberate:
--   * no indexes on the parent, so ATTACH never has to build one;
--   * no PK, because cold data does not need uniqueness enforcement;
--   * each attached partition keeps whatever indexes IT has, and they
--     do not have to be uniform across partitions. That freedom is
--     what lets us slim the cold partitions down individually.
-- ---------------------------------------------------------------------
CREATE TABLE archive.wallet_ledger (LIKE core.wallet_ledger)
    PARTITION BY RANGE (created_at);

COMMENT ON TABLE archive.wallet_ledger IS
    'Cold ledger partitions, detached from core.wallet_ledger after the hot retention window.';

UPDATE ops.partition_config
   SET archive_parent = 'archive.wallet_ledger'::regclass
 WHERE parent_table = 'core.wallet_ledger'::regclass;

-- ---------------------------------------------------------------------
-- Which partitions are due? A partition is archivable only when its
-- UPPER bound is already older than the cutoff — i.e. it cannot
-- possibly contain a row that is still inside the hot window.
--
-- This is why monthly granularity gives you 90-120 days hot rather than
-- exactly 90. Switch ops.partition_config.granularity to 'week' if you
-- need the window tighter.
-- ---------------------------------------------------------------------
CREATE FUNCTION ops.partitions_due_for_archive(parent regclass)
RETURNS TABLE (partition regclass, lower_bound timestamptz, upper_bound timestamptz)
LANGUAGE sql STABLE AS $$
    SELECT c.oid::regclass, b.lower_bound, b.upper_bound
      FROM ops.partition_config cfg
      JOIN pg_inherits i ON i.inhparent = cfg.parent_table
      JOIN pg_class c    ON c.oid = i.inhrelid
      CROSS JOIN LATERAL ops.partition_bounds(c.oid) b
     WHERE cfg.parent_table = parent
       AND b.upper_bound IS NOT NULL
       AND b.upper_bound <= now() - cfg.hot_retention
     ORDER BY b.lower_bound;
$$;

-- ---------------------------------------------------------------------
-- The generator.
--
--   slim = true  also rewrites the cold partition's indexes:
--                drop the ones that only served the transactional
--                workload, keep the one reporting still needs, and add
--                a BRIN index on created_at (a few KB instead of tens
--                of MB, because rows inside a partition are physically
--                ordered by time).
--
-- Step by step, and why each step is there:
--
--  1-2  Add an explicit CHECK matching the partition bounds, NOT VALID,
--       then VALIDATE it. The implicit partition constraint disappears
--       the moment the table is detached, and ATTACH refuses to trust
--       you without proof: without this constraint, ATTACH does a full
--       table scan holding ACCESS EXCLUSIVE. With it, ATTACH is
--       instant. ADD ... NOT VALID takes a brief ACCESS EXCLUSIVE lock
--       and no scan; VALIDATE scans but only under SHARE UPDATE
--       EXCLUSIVE, so writes keep flowing.
--
--   3   DETACH ... CONCURRENTLY. Two internal transactions, a brief
--       lock at each end, and a wait for older snapshots in between.
--       No ACCESS EXCLUSIVE held across the scan.
--
--   4   Move the table out of the hot schema. Pure catalog update.
--
--   5   ATTACH to the archive parent. Scan-free thanks to step 2.
--
--  6-8  Cold-storage housekeeping: slim the indexes, turn autovacuum
--       off on a table that will never be written again, and VACUUM
--       FREEZE it once so it never needs an anti-wraparound vacuum.
-- ---------------------------------------------------------------------
CREATE FUNCTION ops.archive_plan(parent regclass, slim boolean DEFAULT true)
RETURNS TABLE (seq int, partition text, statement text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    cfg       ops.partition_config;
    rec       record;
    part_name name;
    arch_nsp  name;
    arch_name name;
    n         int := 0;
BEGIN
    SELECT * INTO cfg FROM ops.partition_config WHERE parent_table = parent;
    IF cfg.archive_parent IS NULL THEN
        RAISE EXCEPTION 'no archive_parent configured for %', parent;
    END IF;

    SELECT n.nspname, c.relname INTO arch_nsp, arch_name
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = cfg.archive_parent;

    FOR rec IN SELECT * FROM ops.partitions_due_for_archive(parent) LOOP
        part_name := rec.partition::regclass::text;
        part_name := split_part(part_name, '.', 2);

        partition := part_name;

        -- Steps 1-2 are skipped if a validated bounds constraint is
        -- already in place — which is the case for a partition that was
        -- archived before and later restored (see 08). Idempotence is
        -- not a nicety here: this job runs unattended, and re-running it
        -- after a partial failure must be harmless.
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conrelid = rec.partition
                          AND conname  = part_name || '_bounds_chk'
                          AND convalidated) THEN
            n := n + 1;  seq := n;
            statement := format(
                'ALTER TABLE %s ADD CONSTRAINT %I CHECK (created_at >= %L AND created_at < %L) NOT VALID;',
                rec.partition, part_name || '_bounds_chk', rec.lower_bound, rec.upper_bound);
            RETURN NEXT;

            n := n + 1;  seq := n;
            statement := format('ALTER TABLE %s VALIDATE CONSTRAINT %I;',
                                rec.partition, part_name || '_bounds_chk');
            RETURN NEXT;
        END IF;

        n := n + 1;  seq := n;
        statement := format('ALTER TABLE %s DETACH PARTITION %s CONCURRENTLY;',
                            parent, rec.partition);
        RETURN NEXT;

        n := n + 1;  seq := n;
        statement := format('ALTER TABLE %s SET SCHEMA %I;', rec.partition, arch_nsp);
        RETURN NEXT;

        n := n + 1;  seq := n;
        statement := format(
            'ALTER TABLE %I.%I ATTACH PARTITION %I.%I FOR VALUES FROM (%L) TO (%L);',
            arch_nsp, arch_name, arch_nsp, part_name, rec.lower_bound, rec.upper_bound);
        RETURN NEXT;

        IF slim THEN
            -- The PK and the idempotency-key index exist to protect
            -- writes. Nothing writes here any more.
            n := n + 1;  seq := n;
            statement := format('ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS %I;',
                                arch_nsp, part_name, part_name || '_pkey');
            RETURN NEXT;

            n := n + 1;  seq := n;
            statement := format('ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS %I;',
                                arch_nsp, part_name, part_name || '_external_ref_created_at_key');
            RETURN NEXT;

            -- Operational "all withdrawals today" index: irrelevant on
            -- cold data. The BRIN below covers time-range scans for a
            -- fraction of the space.
            n := n + 1;  seq := n;
            statement := format('DROP INDEX IF EXISTS %I.%I;',
                                arch_nsp, part_name || '_event_type_created_at_idx');
            RETURN NEXT;

            n := n + 1;  seq := n;
            statement := format(
                'CREATE INDEX IF NOT EXISTS %I ON %I.%I USING brin (created_at) WITH (pages_per_range = 32);',
                part_name || '_created_at_brin', arch_nsp, part_name);
            RETURN NEXT;
        END IF;

        n := n + 1;  seq := n;
        statement := format(
            'ALTER TABLE %I.%I SET (autovacuum_enabled = off, toast.autovacuum_enabled = off);',
            arch_nsp, part_name);
        RETURN NEXT;

        -- VACUUM FULL would also compact the heap, but it needs ACCESS
        -- EXCLUSIVE and twice the disk. FREEZE is the cheap win: it
        -- marks every tuple frozen so this table never triggers an
        -- anti-wraparound vacuum again.
        n := n + 1;  seq := n;
        statement := format('VACUUM (FREEZE, ANALYZE) %I.%I;', arch_nsp, part_name);
        RETURN NEXT;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- Cold retention: what may be dropped from the archive entirely.
-- Deliberately a separate function from archiving, because DROP is the
-- one irreversible step in this whole design.
-- ---------------------------------------------------------------------
CREATE FUNCTION ops.purge_plan(parent regclass)
RETURNS TABLE (partition text, upper_bound timestamptz, statement text)
LANGUAGE sql STABLE AS $$
    SELECT c.oid::regclass::text,
           b.upper_bound,
           format('DROP TABLE %s;', c.oid::regclass)
      FROM ops.partition_config cfg
      JOIN pg_inherits i ON i.inhparent = cfg.archive_parent
      JOIN pg_class c    ON c.oid = i.inhrelid
      CROSS JOIN LATERAL ops.partition_bounds(c.oid) b
     WHERE cfg.parent_table = parent
       AND cfg.cold_retention IS NOT NULL
       AND b.upper_bound IS NOT NULL
       AND b.upper_bound <= now() - cfg.cold_retention
     ORDER BY b.lower_bound;
$$;

-- ---------------------------------------------------------------------
-- Pulling a partition back from cold storage. Rare, but the day you
-- need it you will not want to invent it under pressure.
-- ---------------------------------------------------------------------
CREATE FUNCTION ops.restore_plan(part regclass, parent regclass)
RETURNS TABLE (seq int, statement text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    b         record;
    part_name name;
    nsp       name;
BEGIN
    SELECT n.nspname, c.relname INTO nsp, part_name
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = part;

    SELECT * INTO b FROM ops.partition_bounds(part);
    IF b.lower_bound IS NULL THEN
        RAISE EXCEPTION '% is not a range partition with usable bounds', part;
    END IF;

    seq := 1;
    statement := format('ALTER TABLE %I.%I DETACH PARTITION %s CONCURRENTLY;',
        (SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.oid = (SELECT inhparent FROM pg_inherits WHERE inhrelid = part)),
        (SELECT c.relname FROM pg_class c
          WHERE c.oid = (SELECT inhparent FROM pg_inherits WHERE inhrelid = part)),
        part);
    RETURN NEXT;

    seq := 2;
    statement := format('ALTER TABLE %s SET (autovacuum_enabled = on, toast.autovacuum_enabled = on);', part);
    RETURN NEXT;

    seq := 3;
    statement := format('ALTER TABLE %s SET SCHEMA %I;', part,
        (SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.oid = parent));
    RETURN NEXT;

    seq := 4;
    statement := format('ALTER TABLE %s ATTACH PARTITION %I.%I FOR VALUES FROM (%L) TO (%L);',
        parent,
        (SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.oid = parent),
        part_name, b.lower_bound, b.upper_bound);
    RETURN NEXT;
END;
$$;

\echo 'Archive toolkit installed. archive.wallet_ledger is ready (empty).'
\echo ''
\echo '--- Partitions currently due for archiving (90-day hot window) ---'
SELECT partition, lower_bound::date, upper_bound::date
  FROM ops.partitions_due_for_archive('core.wallet_ledger');
