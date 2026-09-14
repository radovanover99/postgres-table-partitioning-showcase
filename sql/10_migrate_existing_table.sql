-- =====================================================================
-- 10_migrate_existing_table.sql
-- "Great, but my transaction table already exists and has 400 million
--  rows in it."
--
-- You cannot ALTER a plain table into a partitioned one. There are two
-- realistic paths, and which one you pick depends on a single question:
--
--   Can you live with all your existing history sitting in ONE big
--   partition?
--
--   YES -> PATH A. Minutes of work, seconds of locking, no data copied.
--          The legacy table becomes the oldest partition. New data goes
--          into properly sized partitions from the cutover onwards, and
--          the big legacy partition ages out of the hot window on its
--          own within one retention period anyway.
--
--   NO  -> PATH B. Build the partitioned table beside the old one,
--          dual-write with a trigger, backfill in batches, swap names.
--          More machinery, but the end state is fully partitioned and
--          you can do it while the system stays online.
--
-- Both paths are runnable below, on their own throwaway tables.
-- =====================================================================
\set ON_ERROR_STOP on
SET timezone = 'UTC';

CREATE SCHEMA IF NOT EXISTS legacy;

-- =====================================================================
-- PATH A — adopt the legacy table as the first partition
-- =====================================================================
\echo ''
\echo '################################################################'
\echo '# PATH A: adopt the existing table as the oldest partition'
\echo '################################################################'

-- --- the "existing production table" --------------------------------
CREATE TABLE legacy.txn_a (
    txn_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id  bigint        NOT NULL,
    amount     numeric(20,8) NOT NULL,
    created_at timestamptz   NOT NULL
);
CREATE INDEX txn_a_player_time_idx ON legacy.txn_a (player_id, created_at DESC);

INSERT INTO legacy.txn_a (player_id, amount, created_at)
SELECT 1 + (g::bigint * 7919) % 5000,
       round((random() * 100 + 0.01)::numeric, 8),
       now() - (g % 180) * interval '1 day'
  FROM generate_series(1, 120000) g;
ANALYZE legacy.txn_a;

SELECT count(*) AS rows, min(created_at)::date AS oldest, max(created_at)::date AS newest
  FROM legacy.txn_a;

-- --- Step A1: prove the bounds, online -------------------------------
-- ATTACH refuses to trust you: without a constraint that proves every
-- row fits the declared range, it scans the whole table under ACCESS
-- EXCLUSIVE. Adding the CHECK as NOT VALID takes a brief ACCESS
-- EXCLUSIVE lock and no scan; VALIDATE does the scan under SHARE UPDATE
-- EXCLUSIVE, which does not block reads or writes.
--
-- Pick the upper bound in the FUTURE, at the cutover moment you intend,
-- so writes have somewhere to go right up to the swap.
\echo ''
\echo '--- A1: bounds constraint (NOT VALID, then VALIDATE) ---'
\timing on
ALTER TABLE legacy.txn_a
    ADD CONSTRAINT txn_a_bounds_chk
    CHECK (created_at >= '2020-01-01 00:00:00+00' AND created_at < '2027-01-01 00:00:00+00')
    NOT VALID;

ALTER TABLE legacy.txn_a VALIDATE CONSTRAINT txn_a_bounds_chk;
\timing off

-- --- Step A2: the primary key has to change --------------------------
-- The partitioned parent's PK must contain the partition key, so
-- (txn_id) becomes (txn_id, created_at). Build the replacement index
-- CONCURRENTLY *before* the swap, then promote it to a constraint —
-- otherwise ATTACH builds it for you, holding ACCESS EXCLUSIVE for the
-- entire build.
\echo ''
\echo '--- A2: build the new PK index concurrently, then promote it ---'
\timing on
CREATE UNIQUE INDEX CONCURRENTLY txn_a_pkey_new ON legacy.txn_a (txn_id, created_at);
\timing off

-- --- Step A3: the swap ----------------------------------------------
-- Everything below is instant catalog work. It belongs in ONE
-- transaction with a lock_timeout so that, if the ledger is busy, the
-- cutover fails and retries instead of parking an ACCESS EXCLUSIVE lock
-- at the head of the queue and stalling every session behind it.
\echo ''
\echo '--- A3: the cutover (one short transaction) ---'
\timing on
BEGIN;
SET LOCAL lock_timeout = '5s';

-- Rename the old table AND its indexes out of the way first. Index
-- names are unique per SCHEMA, not per table: leave the old index
-- called txn_a_pkey and creating the new parent's primary key fails
-- with "relation txn_a_pkey already exists".
ALTER TABLE legacy.txn_a RENAME TO txn_a_p_legacy;
ALTER INDEX legacy.txn_a_player_time_idx RENAME TO txn_a_p_legacy_player_time_idx;

ALTER TABLE legacy.txn_a_p_legacy DROP CONSTRAINT txn_a_pkey;
ALTER TABLE legacy.txn_a_p_legacy
    ADD CONSTRAINT txn_a_p_legacy_pkey PRIMARY KEY USING INDEX txn_a_pkey_new;

CREATE TABLE legacy.txn_a (
    txn_id     bigint        NOT NULL,
    player_id  bigint        NOT NULL,
    amount     numeric(20,8) NOT NULL,
    created_at timestamptz   NOT NULL,
    CONSTRAINT txn_a_pkey PRIMARY KEY (txn_id, created_at)
) PARTITION BY RANGE (created_at);

CREATE INDEX txn_a_player_time_idx ON legacy.txn_a (player_id, created_at DESC);

-- Scan-free, thanks to A1 and A2.
ALTER TABLE legacy.txn_a
    ATTACH PARTITION legacy.txn_a_p_legacy
    FOR VALUES FROM ('2020-01-01 00:00:00+00') TO ('2027-01-01 00:00:00+00');

COMMIT;
\timing off

\echo ''
\echo '--- Result: same table name, same data, now partitioned ---'
SELECT count(*) FROM legacy.txn_a;
SELECT partition, lower_bound::date, upper_bound::date, total_size
  FROM ops.list_partitions('legacy.txn_a');

-- ---------------------------------------------------------------------
-- Loose ends for Path A, in the order you should deal with them:
--
--  * The sequence behind the old identity column stayed with the old
--    table. Re-point it at the new parent, or (simpler) declare the
--    column as identity on the new parent and set the sequence value:
--        ALTER TABLE legacy.txn_a
--            ALTER COLUMN txn_id ADD GENERATED BY DEFAULT AS IDENTITY;
--        SELECT setval(pg_get_serial_sequence('legacy.txn_a','txn_id'),
--                      (SELECT max(txn_id) FROM legacy.txn_a));
--
--  * Foreign keys that pointed at the old table were dropped with the
--    rename of its primary key; recreate them against the new parent.
--
--  * Register the table with the toolkit and create the forward
--    partitions BEFORE the legacy partition's upper bound arrives:
--        INSERT INTO ops.partition_config ... ;
--        SELECT ops.ensure_partitions('legacy.txn_a');
--    Note ops.partition_config stores a regclass (an OID), so the row
--    survives the RENAME above without any maintenance.
--
--  * The big legacy partition can be split later, offline, by creating
--    proper monthly partitions and moving rows into them month by
--    month — or simply left to age out of the hot window.
-- ---------------------------------------------------------------------

-- =====================================================================
-- PATH B — build beside, dual-write, backfill, swap
-- =====================================================================
\echo ''
\echo '################################################################'
\echo '# PATH B: dual-write + batched backfill + name swap'
\echo '################################################################'

CREATE TABLE legacy.txn_b (
    txn_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id  bigint        NOT NULL,
    amount     numeric(20,8) NOT NULL,
    created_at timestamptz   NOT NULL
);
INSERT INTO legacy.txn_b (player_id, amount, created_at)
SELECT 1 + (g::bigint * 7919) % 5000,
       round((random() * 100 + 0.01)::numeric, 8),
       now() - (g % 180) * interval '1 day'
  FROM generate_series(1, 120000) g;
ANALYZE legacy.txn_b;

-- --- Step B1: the destination ----------------------------------------
\echo ''
\echo '--- B1: create the partitioned destination and its partitions ---'
CREATE TABLE legacy.txn_b_new (
    txn_id     bigint        NOT NULL,
    player_id  bigint        NOT NULL,
    amount     numeric(20,8) NOT NULL,
    created_at timestamptz   NOT NULL,
    CONSTRAINT txn_b_new_pkey PRIMARY KEY (txn_id, created_at)
) PARTITION BY RANGE (created_at);

CREATE INDEX txn_b_new_player_time_idx ON legacy.txn_b_new (player_id, created_at DESC);

INSERT INTO ops.partition_config
    (parent_table, granularity, premake, hot_retention)
VALUES
    ('legacy.txn_b_new'::regclass, 'month', 3, interval '90 days');

SELECT ops.ensure_partitions('legacy.txn_b_new', now() - interval '12 months');

-- --- Step B2: dual-write ---------------------------------------------
-- From here on every write to the old table is mirrored to the new one.
-- ON CONFLICT DO NOTHING makes the trigger and the backfill safe to
-- overlap: whichever gets there first wins, the other is a no-op.
\echo ''
\echo '--- B2: dual-write trigger ---'
CREATE FUNCTION legacy.txn_b_mirror() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO legacy.txn_b_new VALUES (NEW.*)
            ON CONFLICT (txn_id, created_at) DO NOTHING;
    ELSIF TG_OP = 'UPDATE' THEN
        -- created_at is the partition key and must never change; if it
        -- can in your system, make this a DELETE + INSERT instead.
        UPDATE legacy.txn_b_new
           SET player_id = NEW.player_id, amount = NEW.amount
         WHERE txn_id = NEW.txn_id AND created_at = NEW.created_at;
    ELSE
        DELETE FROM legacy.txn_b_new
         WHERE txn_id = OLD.txn_id AND created_at = OLD.created_at;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER txn_b_mirror_trg
    AFTER INSERT OR UPDATE OR DELETE ON legacy.txn_b
    FOR EACH ROW EXECUTE FUNCTION legacy.txn_b_mirror();

-- --- Step B3: batched backfill ---------------------------------------
-- A single INSERT ... SELECT of 400 million rows is one enormous
-- transaction: it bloats WAL, holds a snapshot open for hours (which
-- blocks vacuum on every table in the cluster) and cannot be resumed.
-- Batch it, COMMIT between batches, and drive it from a watermark so
-- it is restartable.
\echo ''
\echo '--- B3: batched backfill ---'
CREATE PROCEDURE legacy.txn_b_backfill(p_batch int DEFAULT 20000)
LANGUAGE plpgsql AS $$
DECLARE
    watermark bigint := 0;
    moved     int;
    total     bigint := 0;
BEGIN
    LOOP
        WITH src AS (
            SELECT * FROM legacy.txn_b
             WHERE txn_id > watermark
             ORDER BY txn_id
             LIMIT p_batch
        ), ins AS (
            INSERT INTO legacy.txn_b_new
            SELECT * FROM src
            ON CONFLICT (txn_id, created_at) DO NOTHING
            RETURNING txn_id
        )
        SELECT coalesce(max(s.txn_id), watermark), count(*)
          INTO watermark, moved
          FROM src s;

        EXIT WHEN moved = 0;
        total := total + moved;
        COMMIT;                 -- release the snapshot between batches
    END LOOP;
    RAISE NOTICE 'backfilled % rows', total;
END;
$$;

\timing on
CALL legacy.txn_b_backfill(20000);
\timing off

-- --- Step B4: verify BEFORE you swap ---------------------------------
\echo ''
\echo '--- B4: verification ---'
SELECT (SELECT count(*) FROM legacy.txn_b)     AS old_rows,
       (SELECT count(*) FROM legacy.txn_b_new) AS new_rows,
       (SELECT count(*) FROM (
            SELECT txn_id, created_at FROM legacy.txn_b
            EXCEPT
            SELECT txn_id, created_at FROM legacy.txn_b_new) d) AS missing_in_new;

-- --- Step B5: the swap ------------------------------------------------
-- Two renames in one transaction. Sessions either see the old table or
-- the new one, never a gap. lock_timeout again, for the same reason.
\echo ''
\echo '--- B5: the swap ---'
\timing on
BEGIN;
SET LOCAL lock_timeout = '5s';
DROP TRIGGER txn_b_mirror_trg ON legacy.txn_b;
ALTER TABLE legacy.txn_b     RENAME TO txn_b_old;
ALTER TABLE legacy.txn_b_new RENAME TO txn_b;
COMMIT;
\timing off

ANALYZE legacy.txn_b;

\echo ''
\echo '--- Result ---'
SELECT count(*) FROM legacy.txn_b;
SELECT partition, lower_bound::date, upper_bound::date, est_rows, total_size
  FROM ops.list_partitions('legacy.txn_b')
 WHERE est_rows > 0
 ORDER BY lower_bound;

\echo ''
\echo '--- Keep legacy.txn_b_old around for a day or two, then DROP it.'
\echo '    That table is your rollback plan; do not rush it. ---'

-- ---------------------------------------------------------------------
-- WHICH PATH?
--
--   Path A costs one short ACCESS EXCLUSIVE lock and no data movement.
--   It is the right answer for an append-only ledger with a retention
--   policy, because the oversized legacy partition is temporary by
--   construction — it archives itself once it falls out of the hot
--   window.
--
--   Path B costs a full copy of the table (disk, WAL, replication lag,
--   hours) and a period of double writes. Take it when the old data
--   must be properly partitioned from day one, or when the legacy
--   table's PK/column layout has to change anyway.
--
--   Path C, worth naming: pg_partman's partition_data_proc, or
--   pgroll/pg_squeeze style tooling. Same ideas, maintained by other
--   people. If you are doing this once, use the tool; the value of the
--   scripts above is knowing what the tool is doing.
-- ---------------------------------------------------------------------
