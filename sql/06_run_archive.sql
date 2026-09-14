-- =====================================================================
-- 06_run_archive.sql
-- Actually move the cold partitions out. This is the heart of the demo.
-- =====================================================================
\set ON_ERROR_STOP on
SET timezone = 'UTC';

-- =====================================================================
-- PART 1 — Why not just DELETE?
-- Everyone's first instinct is "DELETE FROM ledger WHERE created_at <
-- now() - interval '90 days'". Here is what that actually does.
-- =====================================================================
\echo ''
\echo '=== The DELETE approach, measured ==============================='

CREATE TABLE ops.delete_demo AS
    SELECT * FROM core.wallet_ledger WHERE created_at >= '2026-06-01' AND created_at < '2026-07-01';
CREATE INDEX ON ops.delete_demo (player_id, created_at DESC);
ANALYZE ops.delete_demo;

SELECT count(*) AS rows_before,
       pg_size_pretty(pg_total_relation_size('ops.delete_demo')) AS size_before
  FROM ops.delete_demo;

\timing on
DELETE FROM ops.delete_demo WHERE created_at < '2026-06-20';
\timing off

SELECT count(*) AS rows_after,
       pg_size_pretty(pg_total_relation_size('ops.delete_demo')) AS size_after
  FROM ops.delete_demo;

\echo '  ^ Rows are gone. The disk space is NOT. Every deleted row left a'
\echo '    dead tuple plus a full WAL record, the indexes still carry the'
\echo '    entries, and autovacuum now has work to do on your busiest'
\echo '    table. Reclaiming the space means VACUUM FULL, which takes an'
\echo '    ACCESS EXCLUSIVE lock — an outage on the ledger.'
\echo ''

-- (cumulative statistics are flushed with a small delay, hence the nap)
SELECT pg_sleep(1);
SELECT n_live_tup, n_dead_tup
  FROM pg_stat_user_tables WHERE relname = 'delete_demo';

\echo ''
\echo '=== The partition approach, measured ============================'
\timing on
DROP TABLE ops.delete_demo;
\timing off
\echo '  ^ Same amount of data removed. A catalog update and an unlink.'
\echo '    No dead tuples, no WAL storm, no vacuum debt, space returned'
\echo '    to the filesystem immediately.'

-- =====================================================================
-- PART 2 — Before
-- =====================================================================
\echo ''
\echo '=== BEFORE ====================================================='
SELECT 'core'    AS tier, count(*) AS rows FROM core.wallet_ledger
UNION ALL
SELECT 'archive' AS tier, count(*)         FROM archive.wallet_ledger;

SELECT partition, lower_bound::date, upper_bound::date, total_size
  FROM ops.list_partitions('core.wallet_ledger');

\echo ''
\echo '=== The plan that is about to run =============================='
SELECT seq, statement FROM ops.archive_plan('core.wallet_ledger') ORDER BY seq;

-- =====================================================================
-- PART 3 — Execute it.
--
-- \gexec runs each returned string as its own statement, outside any
-- transaction block. That is mandatory here: DETACH ... CONCURRENTLY
-- and VACUUM both refuse to run inside one.
--
-- Deliberately NOT wrapped in BEGIN/COMMIT. If it fails halfway you are
-- left in a well-defined state — some partitions archived, some not —
-- and re-running the generator simply picks up where it stopped,
-- because it reads the catalog rather than a checkpoint file.
-- =====================================================================
\echo ''
\echo '=== RUNNING ===================================================='
\timing on
SELECT statement FROM ops.archive_plan('core.wallet_ledger') ORDER BY seq \gexec
\timing off

-- =====================================================================
-- PART 4 — After
-- =====================================================================
\echo ''
\echo '=== AFTER ======================================================'
SELECT 'core'    AS tier, count(*) AS rows FROM core.wallet_ledger
UNION ALL
SELECT 'archive' AS tier, count(*)         FROM archive.wallet_ledger;

\echo ''
\echo '--- Hot partitions ---'
SELECT partition, lower_bound::date, upper_bound::date, total_size
  FROM ops.list_partitions('core.wallet_ledger');

\echo ''
\echo '--- Archived partitions (note the smaller total size: the cold'
\echo '    partitions gave up two btree indexes and gained one BRIN) ---'
SELECT partition, lower_bound::date, upper_bound::date, total_size
  FROM ops.list_partitions('archive.wallet_ledger');

\echo ''
\echo '--- Index footprint, hot vs cold, for one comparable month ---'
SELECT c.oid::regclass::text AS relation,
       pg_size_pretty(pg_relation_size(c.oid))       AS heap,
       pg_size_pretty(pg_indexes_size(c.oid))        AS indexes
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE (n.nspname, c.relname) IN (('core','wallet_ledger_p2026_08'),
                                  ('archive','wallet_ledger_p2026_05'))
 ORDER BY 1;

-- =====================================================================
-- PART 5 — The gotcha nobody warns you about.
--
-- DETACH ... CONCURRENTLY works in two transactions and waits in
-- between for older snapshots to finish. If the session is killed, or
-- you hit statement_timeout, or a long-running reporting query blocks
-- it, the partition is left in a half-detached state. It still shows in
-- pg_inherits, with inhdetachpending = true, and the parent table
-- REFUSES most DDL until you resolve it.
--
-- The fix is one command:
--     ALTER TABLE core.wallet_ledger DETACH PARTITION <part> FINALIZE;
--
-- Put this check in your monitoring. It should always return zero rows.
-- =====================================================================
\echo ''
\echo '--- Half-detached partitions (must be empty) ---'
SELECT i.inhparent::regclass AS parent,
       i.inhrelid::regclass  AS stuck_partition,
       format('ALTER TABLE %s DETACH PARTITION %s FINALIZE;',
              i.inhparent::regclass, i.inhrelid::regclass) AS fix
  FROM pg_inherits i
 WHERE i.inhdetachpending;
