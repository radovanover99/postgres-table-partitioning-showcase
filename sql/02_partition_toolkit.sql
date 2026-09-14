-- =====================================================================
-- 02_partition_toolkit.sql
-- A small, config-driven toolkit for creating and inspecting partitions.
--
-- Everything below is generic: it works for any range-partitioned table
-- with a timestamptz key. Granularity is a config value, so switching
-- from monthly to weekly is a one-word UPDATE, not a rewrite.
--
-- NOTE: pg_partman does all of this and more, and is the right answer in
-- production. This file exists so the showcase has no dependency on an
-- extension and so you can SEE what the automation is actually doing.
-- =====================================================================
\set ON_ERROR_STOP on
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- One row per partitioned table. This is the whole control surface.
-- ---------------------------------------------------------------------
CREATE TABLE ops.partition_config (
    parent_table   regclass PRIMARY KEY,
    granularity    text     NOT NULL CHECK (granularity IN ('day', 'week', 'month')),
    premake        int      NOT NULL DEFAULT 3,   -- future partitions kept ready
    hot_retention  interval NOT NULL,             -- how long data stays in the hot parent
    archive_parent regclass,                      -- where detached partitions are re-attached
    cold_retention interval,                      -- drop from archive after this (NULL = keep forever)
    CONSTRAINT premake_positive CHECK (premake >= 1)
);

COMMENT ON TABLE ops.partition_config IS
    'Declarative partition/retention policy, one row per partitioned parent table.';

-- ---------------------------------------------------------------------
-- Bucket maths. date_trunc() with an explicit timezone argument keeps
-- the boundaries honest no matter what the calling session's TimeZone is.
-- ---------------------------------------------------------------------
CREATE FUNCTION ops.bucket_start(ts timestamptz, granularity text)
RETURNS timestamptz
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT date_trunc(granularity, ts, 'UTC');
$$;

CREATE FUNCTION ops.bucket_step(granularity text)
RETURNS interval
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT ('1 ' || granularity)::interval;
$$;

-- Partition naming. Readable names matter: you will read these in
-- pg_stat_user_tables, in EXPLAIN plans and in PagerDuty alerts.
CREATE FUNCTION ops.partition_suffix(ts timestamptz, granularity text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE granularity
        WHEN 'month' THEN to_char(ts AT TIME ZONE 'UTC', '"p"YYYY_MM')
        WHEN 'week'  THEN to_char(ts AT TIME ZONE 'UTC', '"p"IYYY"w"IW')
        WHEN 'day'   THEN to_char(ts AT TIME ZONE 'UTC', '"p"YYYY_MM_DD')
    END;
$$;

-- ---------------------------------------------------------------------
-- Read a partition's bounds back out of the catalog.
-- pg_get_expr(relpartbound) renders as:
--     FOR VALUES FROM ('2026-01-01 00:00:00+00') TO ('2026-02-01 00:00:00+00')
-- Returns NULLs for a DEFAULT partition or for MINVALUE/MAXVALUE bounds.
-- ---------------------------------------------------------------------
CREATE FUNCTION ops.partition_bounds(part regclass,
                                     OUT lower_bound timestamptz,
                                     OUT upper_bound timestamptz)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    expr text;
    m    text[];
BEGIN
    SELECT pg_get_expr(c.relpartbound, c.oid)
      INTO expr
      FROM pg_class c
     WHERE c.oid = part;

    m := regexp_match(expr, $re$FOR VALUES FROM \('([^']+)'\) TO \('([^']+)'\)$re$);
    IF m IS NULL THEN
        RETURN;                      -- DEFAULT partition, or not a partition
    END IF;

    lower_bound := m[1]::timestamptz;
    upper_bound := m[2]::timestamptz;
END;
$$;

-- ---------------------------------------------------------------------
-- Create one partition if it is missing. Idempotent.
-- The partition is created in the same schema as its parent.
-- ---------------------------------------------------------------------
CREATE FUNCTION ops.create_partition(parent regclass, bucket timestamptz)
RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    cfg       ops.partition_config;
    nsp       name;
    base      name;
    part_name name;
    lo        timestamptz;
    hi        timestamptz;
BEGIN
    SELECT * INTO cfg FROM ops.partition_config WHERE parent_table = parent;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no ops.partition_config row for %', parent;
    END IF;

    SELECT n.nspname, c.relname INTO nsp, base
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = parent;

    lo := ops.bucket_start(bucket, cfg.granularity);
    hi := lo + ops.bucket_step(cfg.granularity);
    part_name := base || '_' || ops.partition_suffix(lo, cfg.granularity);

    IF to_regclass(format('%I.%I', nsp, part_name)) IS NOT NULL THEN
        RETURN NULL;                 -- already there
    END IF;

    EXECUTE format(
        'CREATE TABLE %I.%I PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
        nsp, part_name, parent::text, lo, hi);

    RETURN format('%I.%I', nsp, part_name);
END;
$$;

-- ---------------------------------------------------------------------
-- Make sure every bucket in a window exists.
--
-- Called with no window it does the normal maintenance job: cover now()
-- plus `premake` future buckets. Called with a window it also backfills
-- historical buckets, which is what the seed script and the migration
-- script need.
--
-- Run this from cron. If it ever has nothing to do, that is the
-- healthy state — it is cheap and idempotent by design.
-- ---------------------------------------------------------------------
CREATE FUNCTION ops.ensure_partitions(parent    regclass,
                                      window_from timestamptz DEFAULT NULL,
                                      window_to   timestamptz DEFAULT NULL)
RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
    cfg     ops.partition_config;
    lo      timestamptz;
    hi      timestamptz;
    cur     timestamptz;
    created text;
BEGIN
    SELECT * INTO cfg FROM ops.partition_config WHERE parent_table = parent;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no ops.partition_config row for %', parent;
    END IF;

    lo := ops.bucket_start(COALESCE(window_from, now()), cfg.granularity);
    hi := ops.bucket_start(COALESCE(window_to,   now()), cfg.granularity)
          + cfg.premake * ops.bucket_step(cfg.granularity);

    cur := lo;
    WHILE cur <= hi LOOP
        created := ops.create_partition(parent, cur);
        IF created IS NOT NULL THEN
            RETURN NEXT created;
        END IF;
        cur := cur + ops.bucket_step(cfg.granularity);
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- Inventory: the query you will actually run every day.
-- ---------------------------------------------------------------------
CREATE FUNCTION ops.list_partitions(parent regclass)
RETURNS TABLE (partition    text,
               lower_bound  timestamptz,
               upper_bound  timestamptz,
               est_rows     bigint,
               total_bytes  bigint,
               total_size   text)
LANGUAGE sql STABLE AS $$
    SELECT c.oid::regclass::text,
           b.lower_bound,
           b.upper_bound,
           c.reltuples::bigint,
           pg_total_relation_size(c.oid),
           pg_size_pretty(pg_total_relation_size(c.oid))
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      CROSS JOIN LATERAL ops.partition_bounds(c.oid) b
     WHERE i.inhparent = parent
     ORDER BY b.lower_bound NULLS LAST;
$$;

-- =====================================================================
-- Register the policy for core.wallet_ledger.
--     hot_retention  = 90 days  -> the requirement
--     granularity    = month    -> so ~90-120 days actually stay hot
--     premake        = 3        -> three months of runway
--     cold_retention = 7 years  -> a plausible financial-records rule
-- The archive_parent column is filled in by 05_archive_toolkit.sql,
-- once the archive table exists.
-- =====================================================================
INSERT INTO ops.partition_config
    (parent_table, granularity, premake, hot_retention, cold_retention)
VALUES
    ('core.wallet_ledger', 'month', 3, interval '90 days', interval '7 years');

\echo 'Partition toolkit installed (ops schema).'
