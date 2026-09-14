-- =====================================================================
-- 07_query_archived_data.sql
-- "Fine, the old data is out of the way. How do I read it?"
--
-- Three access paths, in order of how often you should reach for them:
--   1. Query archive.wallet_ledger directly (reports, compliance, BI).
--   2. Query reporting.wallet_ledger_all, a UNION ALL view over both
--      tiers, when a query legitimately spans the boundary.
--   3. Pull a partition back into the hot table (08_...).
--
-- The important property: archived data is still ordinary Postgres
-- data. Same SQL, same indexes, same transactions, same backups. This
-- is the main reason to archive inside Postgres rather than to S3 —
-- nobody has to learn a second query engine to answer "what did this
-- player do 14 months ago".
-- =====================================================================
\set ON_ERROR_STOP on
SET timezone = 'UTC';
\timing on

-- =====================================================================
-- PATH 1 — straight at the archive.
-- It is a partitioned table like any other, so pruning works normally.
-- =====================================================================
\echo ''
\echo '=== Direct archive query ======================================='
SELECT date_trunc('month', created_at)::date AS month,
       event_type,
       count(*),
       round(sum(amount), 2) AS total
  FROM archive.wallet_ledger
 WHERE created_at >= '2026-02-01' AND created_at < '2026-04-01'
 GROUP BY 1, 2
 ORDER BY 1, 2;

\echo '--- and its plan: only the two relevant cold partitions ---'
EXPLAIN (COSTS OFF)
SELECT count(*) FROM archive.wallet_ledger
 WHERE created_at >= '2026-02-01' AND created_at < '2026-04-01';

\echo ''
\echo '--- the BRIN index we added in 05 does the heavy lifting for'
\echo '    wide time ranges inside a single cold partition, at ~1/100th'
\echo '    the size of the btree it replaced ---'
SELECT indexrelid::regclass AS index,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
  FROM pg_index
 WHERE indrelid = 'archive.wallet_ledger_p2026_03'::regclass
 ORDER BY 2;

-- =====================================================================
-- PATH 2 — the unified view.
--
-- A plain UNION ALL. No smart routing, no extension, nothing clever:
-- the planner prunes each branch independently and drops whichever one
-- cannot contribute. The `tier` column is there so a human reading the
-- result can see where each row came from — drop it if you want the
-- view to be a drop-in replacement for the table.
-- =====================================================================
CREATE VIEW reporting.wallet_ledger_all AS
    SELECT 'hot'::text     AS tier, l.* FROM core.wallet_ledger    l
    UNION ALL
    SELECT 'archive'::text AS tier, l.* FROM archive.wallet_ledger l;

COMMENT ON VIEW reporting.wallet_ledger_all IS
    'All ledger history, hot and archived. Read-only: writes go to core.wallet_ledger.';

\echo ''
\echo '=== Unified view: a range entirely inside the hot window ========'
\echo '    Expect: the archive branch disappears from the plan.'
EXPLAIN (COSTS OFF)
SELECT count(*) FROM reporting.wallet_ledger_all
 WHERE created_at >= '2026-08-01' AND created_at < '2026-09-01';

\echo ''
\echo '=== Unified view: a range entirely in the archive ==============='
\echo '    Expect: the hot branch disappears instead.'
EXPLAIN (COSTS OFF)
SELECT count(*) FROM reporting.wallet_ledger_all
 WHERE created_at >= '2026-02-01' AND created_at < '2026-03-01';

\echo ''
\echo '=== Unified view: a range that straddles the boundary ==========='
\echo '    Expect: exactly two partitions, one from each tier.'
EXPLAIN (COSTS OFF)
SELECT count(*) FROM reporting.wallet_ledger_all
 WHERE created_at >= '2026-05-15' AND created_at < '2026-06-15';

\echo ''
\echo '=== The real use case: a full player statement across tiers ====='
SELECT tier, count(*) AS entries,
       min(created_at)::date AS first_entry,
       max(created_at)::date AS last_entry
  FROM reporting.wallet_ledger_all
 WHERE player_id = 42
 GROUP BY tier
 ORDER BY tier;

\echo ''
\echo '--- Note this stays fully indexed: the cold partitions kept'
\echo '    their (player_id, created_at) btree. Slimming cold indexes'
\echo '    is a per-index judgement call, not "drop everything". ---'
EXPLAIN (COSTS OFF, ANALYZE, TIMING OFF, SUMMARY OFF)
SELECT tier, entry_id, created_at, amount
  FROM reporting.wallet_ledger_all
 WHERE player_id = 42
   AND created_at >= '2026-01-01' AND created_at < '2026-04-01'
 ORDER BY created_at;

\timing off

-- =====================================================================
-- THINGS TO KNOW ABOUT THE VIEW
--
-- * It is READ-ONLY. A UNION ALL view is not auto-updatable. That is a
--   feature: writes belong in core.wallet_ledger, and an INSERT that
--   silently landed in an archived month would be a bug, not a
--   convenience. If your application must keep one table name for both,
--   point writes at core.wallet_ledger and reads at the view.
--
-- * Pruning depends on CONSTANTS, same as in 04. A view over a UNION
--   ALL with `created_at > now() - interval '2 years'` will fall back to
--   runtime pruning. For BI tools that generate literal dates, this is
--   the happy path.
--
-- * The two tiers have disjoint ranges by construction, so there is no
--   double counting — the explicit CHECK constraint added in step 1 of
--   the archive plan is also what lets constraint exclusion reason
--   about a detached partition before it is re-attached.
--
-- * Permissions get simpler, not harder: GRANT SELECT on the archive
--   schema to analysts and nothing else. They can read seven years of
--   history and cannot touch the ledger.
--
-- * Backups: because archived partitions never change, you can exclude
--   the archive schema from your frequent logical dumps
--       pg_dump --exclude-schema=archive
--   and dump it separately, once, per partition:
--       pg_dump -t 'archive.wallet_ledger_p2026_01' -Fc -f 2026_01.dump
--   That is also your "cheap cold storage" answer if you later want the
--   oldest partitions out of the database entirely: dump, verify, DROP.
-- =====================================================================
