-- =====================================================================
-- 08_cold_retention_and_restore.sql
-- The two remaining lifecycle operations:
--   A. Pulling an archived partition back into the hot table.
--   B. Dropping archived data for good, once cold retention expires.
-- =====================================================================
\set ON_ERROR_STOP on
SET timezone = 'UTC';

-- =====================================================================
-- A. RESTORE
--
-- Someone opens a dispute about a transaction from eight months ago and
-- the fraud team wants to run its normal tooling against it, not a
-- reporting view. Move the partition back.
--
-- This is the exact reverse of the archive plan, and it is the reason
-- the slimming step in 05 is a judgement call rather than a reflex:
-- ATTACH has to rebuild every index the hot parent declares and the
-- partition no longer has. Below, watch the timing of the ATTACH
-- statement — that is the PK and the unique index being built.
-- =====================================================================
\echo ''
\echo '=== A. Restoring archive.wallet_ledger_p2026_05 to the hot table ==='
SELECT seq, statement
  FROM ops.restore_plan('archive.wallet_ledger_p2026_05', 'core.wallet_ledger')
 ORDER BY seq;

\timing on
SELECT statement
  FROM ops.restore_plan('archive.wallet_ledger_p2026_05', 'core.wallet_ledger')
 ORDER BY seq \gexec
\timing off

\echo ''
\echo '--- It is a first-class hot partition again ---'
SELECT partition, lower_bound::date, upper_bound::date, total_size
  FROM ops.list_partitions('core.wallet_ledger')
 ORDER BY lower_bound;

\echo ''
\echo '--- Two leftovers worth cleaning up after a restore ---'
\echo '  1. the BRIN index, which is pure overhead on a hot partition'
\echo '  2. nothing else: the _bounds_chk CHECK is now redundant with'
\echo '     the partition constraint, but leaving it means the NEXT'
\echo '     archive run can skip the ADD/VALIDATE steps entirely.'
DROP INDEX IF EXISTS core.wallet_ledger_p2026_05_created_at_brin;

\echo ''
\echo '--- Put it back in the archive where it belongs ---'
SELECT statement FROM ops.archive_plan('core.wallet_ledger') ORDER BY seq \gexec

SELECT 'core' AS tier, count(*) FROM core.wallet_ledger
UNION ALL
SELECT 'archive', count(*) FROM archive.wallet_ledger;

-- =====================================================================
-- B. COLD RETENTION
--
-- DROP is the only irreversible step in this design, so it gets its own
-- function, its own script section, and a dump-first habit.
--
-- The demo policy is 7 years, so nothing is due. Temporarily tighten it
-- to see the plan the job would produce.
-- =====================================================================
\echo ''
\echo '=== B. Cold retention ==========================================='
\echo '--- With the real 7-year policy: ---'
SELECT count(*) AS partitions_due FROM ops.purge_plan('core.wallet_ledger');

\echo ''
\echo '--- Pretending the policy were 6 months: ---'
UPDATE ops.partition_config
   SET cold_retention = interval '6 months'
 WHERE parent_table = 'core.wallet_ledger'::regclass;

SELECT partition, upper_bound::date AS data_ends, statement
  FROM ops.purge_plan('core.wallet_ledger');

-- ---------------------------------------------------------------------
-- Dump before you drop. One partition, one file, one command — and
-- because the partition is frozen and never changes, the dump is
-- byte-stable and can go straight to object storage:
--
--   pg_dump -Fc -t 'archive.wallet_ledger_p2026_01' \
--           -f wallet_ledger_2026_01.dump ledgerdb
--
-- Restoring it later is equally boring:
--
--   pg_restore -d ledgerdb wallet_ledger_2026_01.dump
--   -- then ALTER TABLE archive.wallet_ledger ATTACH PARTITION ...
--
-- scripts/archive.sh does the dump automatically before any DROP.
-- ---------------------------------------------------------------------

\echo ''
\echo '--- Executing the purge (in the demo; in production the dump'
\echo '    happens first and a human approves the list) ---'
\timing on
SELECT statement FROM ops.purge_plan('core.wallet_ledger') \gexec
\timing off

-- Restore the sane policy.
UPDATE ops.partition_config
   SET cold_retention = interval '7 years'
 WHERE parent_table = 'core.wallet_ledger'::regclass;

\echo ''
\echo '=== Final state ================================================'
SELECT 'hot'     AS tier, partition, lower_bound::date, upper_bound::date, total_size
  FROM ops.list_partitions('core.wallet_ledger')
UNION ALL
SELECT 'archive', partition, lower_bound::date, upper_bound::date, total_size
  FROM ops.list_partitions('archive.wallet_ledger')
 ORDER BY 3;
