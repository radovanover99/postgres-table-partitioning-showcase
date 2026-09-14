-- =====================================================================
-- 04_hot_queries_and_pruning.sql
-- Partitioning only pays off if the planner can throw partitions away.
-- This file shows exactly when it can, when it can't, and what the
-- plans look like in each case.
--
-- Two different mechanisms, and people mix them up constantly:
--
--   PLAN-TIME PRUNING   the WHERE clause has constants, so the planner
--                       removes partitions before execution and they
--                       never appear in the plan at all.
--
--   RUNTIME PRUNING     the value is not known at plan time (now(), a
--                       bind parameter, a subquery result). The plan
--                       contains an Append over many partitions, and
--                       the executor skips them. EXPLAIN alone hides
--                       this; you need EXPLAIN ANALYZE to see the
--                       "Subplans Removed: N" line.
-- =====================================================================
\set ON_ERROR_STOP on
SET timezone = 'UTC';
\timing on

\echo ''
\echo '###############################################################'
\echo '# A. Literal bounds -> plan-time pruning. One partition in the'
\echo '#    plan. This is the best case and what you should aim for.'
\echo '###############################################################'
EXPLAIN (COSTS OFF)
SELECT count(*), sum(amount)
  FROM core.wallet_ledger
 WHERE created_at >= '2026-09-01' AND created_at < '2026-10-01';

\echo ''
\echo '###############################################################'
\echo '# B. now()-based window -> RUNTIME pruning.'
\echo '#    now() is STABLE, not IMMUTABLE, so the planner cannot fold'
\echo '#    it into a constant. Look for "Subplans Removed" and for'
\echo '#    partitions with (actual rows=0 loops=1) that were kept in'
\echo '#    the plan but never really touched.'
\echo '#'
\echo '#    This is FINE. It is the same reason a now()-based partial'
\echo '#    index predicate is planner-unfriendly, but for partitions'
\echo '#    the executor saves you. Still, when you generate a report'
\echo '#    range in the application, send literal timestamps.'
\echo '###############################################################'
EXPLAIN (COSTS OFF, ANALYZE, TIMING OFF, SUMMARY OFF)
SELECT count(*), sum(amount)
  FROM core.wallet_ledger
 WHERE created_at >= now() - interval '7 days';

\echo ''
\echo '###############################################################'
\echo '# C. The money query: one player, recent activity.'
\echo '#    Partition pruning first, then the local btree inside the'
\echo '#    surviving partitions. Note there is no global index — the'
\echo '#    per-partition indexes are what make this fast.'
\echo '###############################################################'
EXPLAIN (COSTS OFF, ANALYZE, TIMING OFF, SUMMARY OFF)
SELECT entry_id, event_type, amount, balance_after, created_at
  FROM core.wallet_ledger
 WHERE player_id = 42
   AND created_at >= '2026-08-01'
 ORDER BY created_at DESC
 LIMIT 50;

\echo ''
\echo '###############################################################'
\echo '# D. THE ANTI-PATTERN: no partition key in the WHERE clause.'
\echo '#    Every partition is probed. With 12 partitions it is merely'
\echo '#    wasteful; with 400 it is a production incident, because the'
\echo '#    planner also has to lock and consider all of them.'
\echo '#'
\echo '#    Fix: make created_at part of every lookup contract. Your'
\echo '#    API returns (entry_id, created_at) together; your service'
\echo '#    passes both back.'
\echo '###############################################################'
EXPLAIN (COSTS OFF)
SELECT * FROM core.wallet_ledger WHERE external_ref = 'ext-123';

\echo ''
\echo '# ... and the same lookup done properly:'
EXPLAIN (COSTS OFF)
SELECT * FROM core.wallet_ledger
 WHERE external_ref = 'ext-123'
   AND created_at >= '2026-06-01' AND created_at < '2026-07-01';

\echo ''
\echo '###############################################################'
\echo '# E. Sorted paging with no time filter at all.'
\echo '#    Partitions are range-ordered on created_at, so ORDER BY'
\echo '#    created_at DESC lets the executor walk them newest-first'
\echo '#    and stop as soon as LIMIT is satisfied. Watch for'
\echo '#    "(never executed)" on the older partitions — no sort, no'
\echo '#    Merge Append needed, the partition order IS the sort order.'
\echo '#'
\echo '#    Caveat: the planner still had to open, lock and cost all 12'
\echo '#    partitions. Cheap at 12, painful at 500. Partition count is'
\echo '#    a planning-time cost you pay on EVERY query.'
\echo '###############################################################'
EXPLAIN (COSTS OFF, ANALYZE, TIMING OFF, SUMMARY OFF)
SELECT entry_id, created_at, amount
  FROM core.wallet_ledger
 WHERE player_id = 42
 ORDER BY created_at DESC
 LIMIT 20;

\echo ''
\echo '###############################################################'
\echo '# F. Bind parameters: same story as now(), runtime pruning.'
\echo '#    Worth showing because every ORM query goes through here.'
\echo '###############################################################'
PREPARE recent_for_player (bigint, timestamptz) AS
    SELECT count(*) FROM core.wallet_ledger
     WHERE player_id = $1 AND created_at >= $2;

-- The first five executions use custom plans; from the sixth Postgres
-- may switch to a generic plan, which is where runtime pruning matters.
EXECUTE recent_for_player(42, '2026-08-01');
EXECUTE recent_for_player(42, '2026-08-01');
EXECUTE recent_for_player(42, '2026-08-01');
EXECUTE recent_for_player(42, '2026-08-01');
EXECUTE recent_for_player(42, '2026-08-01');
EXPLAIN (COSTS OFF, ANALYZE, TIMING OFF, SUMMARY OFF)
EXECUTE recent_for_player(42, '2026-08-01');
DEALLOCATE recent_for_player;

\echo ''
\echo '###############################################################'
\echo '# G. Joins still work normally, including partitionwise joins.'
\echo '#    enable_partitionwise_join / _aggregate are OFF by default'
\echo '#    because they cost planning time and memory — turn them on'
\echo '#    deliberately, per session or per workload, not globally'
\echo '#    without measuring.'
\echo '###############################################################'
SET enable_partitionwise_aggregate = on;
EXPLAIN (COSTS OFF)
SELECT p.country, count(*)
  FROM core.wallet_ledger l
  JOIN core.player p USING (player_id)
 WHERE l.created_at >= '2026-09-01'
 GROUP BY p.country;
RESET enable_partitionwise_aggregate;

\timing off
\echo ''
\echo '--- Takeaways -------------------------------------------------'
\echo '  * Constants in the WHERE clause  -> partitions vanish from the plan.'
\echo '  * now() / $1 / subqueries        -> "Subplans Removed" at run time.'
\echo '  * No partition key               -> every partition is touched.'
\echo '  * enable_partition_pruning is ON by default; never turn it off.'
\echo '  * constraint_exclusion is a DIFFERENT, older mechanism that'
\echo '    applies to CHECK constraints (inheritance, UNION ALL views).'
\echo '    You will need it in 07_query_archived_data.sql.'
\echo '---------------------------------------------------------------'
