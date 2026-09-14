-- =====================================================================
-- 09_operations_and_monitoring.sql
-- The part that decides whether this design survives contact with
-- production: what you watch, what you automate, and how you change
-- the schema afterwards without taking the ledger down.
-- =====================================================================
\set ON_ERROR_STOP on
SET timezone = 'UTC';

-- =====================================================================
-- 1. THE DASHBOARD QUERY
-- One row per partition, both tiers, sizes and freshness.
-- =====================================================================
\echo ''
\echo '=== Partition inventory (both tiers) ==========================='
CREATE VIEW ops.ledger_partitions AS
    SELECT 'hot'     AS tier, * FROM ops.list_partitions('core.wallet_ledger')
    UNION ALL
    SELECT 'archive' AS tier, * FROM ops.list_partitions('archive.wallet_ledger');

SELECT tier, partition, lower_bound::date, upper_bound::date, est_rows, total_size
  FROM ops.ledger_partitions
 ORDER BY lower_bound;

\echo ''
\echo '=== Storage split ==============================================='
SELECT tier,
       count(*)                        AS partitions,
       sum(est_rows)::bigint           AS est_rows,
       pg_size_pretty(sum(total_bytes)) AS total
  FROM ops.ledger_partitions
 GROUP BY tier
 ORDER BY tier;

-- =====================================================================
-- 2. THE ALERT THAT ACTUALLY MATTERS: RUNWAY
--
-- With no default partition, running out of future partitions is an
-- outage: inserts start failing with "no partition of relation ... found
-- for row". Page on this, and page early — days, not hours.
-- =====================================================================
\echo ''
\echo '=== Partition runway ==========================================='
CREATE VIEW ops.partition_runway AS
    SELECT cfg.parent_table::text AS parent,
           max(b.upper_bound)     AS covered_until,
           (max(b.upper_bound) - now())::interval AS runway,
           CASE
               WHEN max(b.upper_bound) < now() + interval '7 days'  THEN 'CRITICAL'
               WHEN max(b.upper_bound) < now() + interval '30 days' THEN 'WARNING'
               ELSE 'OK'
           END AS status
      FROM ops.partition_config cfg
      JOIN pg_inherits i ON i.inhparent = cfg.parent_table
      JOIN pg_class c    ON c.oid = i.inhrelid
      CROSS JOIN LATERAL ops.partition_bounds(c.oid) b
     GROUP BY cfg.parent_table;

SELECT * FROM ops.partition_runway;

-- =====================================================================
-- 3. HALF-DETACHED PARTITIONS
-- Must always be empty. See the explanation at the end of 06.
-- =====================================================================
\echo ''
\echo '=== Stuck DETACH CONCURRENTLY (must be empty) =================='
SELECT i.inhparent::regclass AS parent,
       i.inhrelid::regclass  AS stuck_partition,
       format('ALTER TABLE %s DETACH PARTITION %s FINALIZE;',
              i.inhparent::regclass, i.inhrelid::regclass) AS fix
  FROM pg_inherits i
 WHERE i.inhdetachpending;

-- =====================================================================
-- 4. VACUUM HEALTH PER PARTITION
-- Partitioning makes this legible: you can see at a glance that the
-- cold partitions are quiet and only the current month is working.
-- =====================================================================
\echo ''
\echo '=== Vacuum / autovacuum per partition =========================='
SELECT s.schemaname || '.' || s.relname AS partition,
       s.n_live_tup, s.n_dead_tup,
       s.last_autovacuum, s.last_autoanalyze
  FROM pg_stat_user_tables s
 WHERE s.relname LIKE 'wallet_ledger_p%'
 ORDER BY s.schemaname, s.relname;

-- =====================================================================
-- 5. ADDING AN INDEX TO A LIVE PARTITIONED TABLE
--
-- The obvious command:
--     CREATE INDEX ... ON core.wallet_ledger (currency, created_at);
-- holds ACCESS EXCLUSIVE on the parent AND every partition for the
-- whole build. On a multi-hundred-GB ledger that is an outage.
--
-- CREATE INDEX CONCURRENTLY is not supported directly on a partitioned
-- table. The supported pattern is three steps:
--
--   a) create an INVALID index on ONLY the parent (catalog entry only,
--      instant, no data touched);
--   b) CREATE INDEX CONCURRENTLY on each partition, one at a time;
--   c) ATTACH each child index to the parent index. When the last one
--      is attached, the parent index flips to valid automatically.
--
-- Between (a) and (c) the parent index is marked invalid and the
-- planner ignores it, so queries are never served a half-built index.
-- =====================================================================
\echo ''
\echo '=== Online index build on a partitioned table =================='

-- (a) parent placeholder
CREATE INDEX wallet_ledger_currency_time_idx
    ON ONLY core.wallet_ledger (currency, created_at DESC);

\echo '--- parent index is INVALID until every child is attached ---'
SELECT indexrelid::regclass AS index, indisvalid
  FROM pg_index WHERE indexrelid = 'core.wallet_ledger_currency_time_idx'::regclass;

-- (b) one concurrent build per partition
SELECT format('CREATE INDEX CONCURRENTLY IF NOT EXISTS %I ON %s (currency, created_at DESC);',
              c.relname || '_currency_created_at_idx', c.oid::regclass)
  FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
 WHERE i.inhparent = 'core.wallet_ledger'::regclass \gexec

-- (c) attach them
SELECT format('ALTER INDEX core.wallet_ledger_currency_time_idx ATTACH PARTITION %I.%I;',
              n.nspname, c.relname || '_currency_created_at_idx')
  FROM pg_inherits i
  JOIN pg_class c     ON c.oid = i.inhrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE i.inhparent = 'core.wallet_ledger'::regclass \gexec

\echo '--- and now it is valid ---'
SELECT indexrelid::regclass AS index, indisvalid
  FROM pg_index WHERE indexrelid = 'core.wallet_ledger_currency_time_idx'::regclass;

-- Not needed by the demo; drop it again so later runs stay clean.
DROP INDEX core.wallet_ledger_currency_time_idx;

-- =====================================================================
-- 6. AUTOMATION
--
-- Two jobs, and they have different requirements.
--
-- (i) Partition creation is a plain function call, so pg_cron is a
--     perfect fit. Run it daily; it is idempotent and usually a no-op.
--
--         CREATE EXTENSION IF NOT EXISTS pg_cron;
--         SELECT cron.schedule(
--             'ledger-ensure-partitions', '0 2 * * *',
--             $$SELECT ops.ensure_partitions('core.wallet_ledger')$$);
--
-- (ii) Archiving CANNOT run under pg_cron as written, because pg_cron
--      executes inside a transaction and DETACH ... CONCURRENTLY (and
--      VACUUM) refuse to run there. Two options:
--
--      * Run scripts/archive.sh from system cron / Kubernetes CronJob.
--        This is the recommended path: it runs the generated statements
--        one by one in autocommit, and dumps partitions before dropping.
--
--      * Or accept a short ACCESS EXCLUSIVE lock and use plain DETACH
--        (no CONCURRENTLY) inside a pg_cron job during a quiet window.
--        Plain DETACH is fast — it does not scan — but it queues behind
--        every open transaction touching the parent, and everything
--        else queues behind IT. Always pair it with a lock_timeout:
--
--            SET lock_timeout = '3s';
--
--        so a blocked maintenance job fails instead of freezing the
--        ledger behind a lock-queue pile-up.
--
-- =====================================================================

-- =====================================================================
-- 7. TWO SETTINGS TO CHECK BEFORE YOU SCALE THE PARTITION COUNT
--
--   max_locks_per_transaction
--       Every partition touched needs a lock slot. A query that fails
--       to prune across 500 partitions, or a pg_dump, can exhaust the
--       shared lock table: "ERROR: out of shared memory / You might
--       need to increase max_locks_per_transaction". Raise it before
--       you go past a few hundred partitions.
--
--   work_mem
--       Append over many partitions can multiply sort/hash memory. If
--       you turn on enable_partitionwise_aggregate or _join, budget for
--       work_mem per partition, not per query.
-- =====================================================================
\echo ''
\echo '=== Relevant settings =========================================='
SELECT name, setting, unit
  FROM pg_settings
 WHERE name IN ('max_locks_per_transaction', 'work_mem',
                'enable_partition_pruning', 'enable_partitionwise_join',
                'enable_partitionwise_aggregate', 'constraint_exclusion')
 ORDER BY name;
