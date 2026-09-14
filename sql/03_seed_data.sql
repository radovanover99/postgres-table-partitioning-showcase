-- =====================================================================
-- 03_seed_data.sql
-- Create the partitions and fill them with ~8 months of ledger traffic,
-- so that some partitions sit inside the 90-day hot window and some are
-- well outside it.
--
-- Tunables (override on the command line):
--     psql -v players=20000 -v entries=2000000 -f sql/03_seed_data.sql
-- =====================================================================
\set ON_ERROR_STOP on
SET timezone = 'UTC';

\if :{?players} \else \set players 5000   \endif
\if :{?entries} \else \set entries 400000 \endif

-- ---------------------------------------------------------------------
-- Step 1: the partitions must exist BEFORE the data arrives.
-- ---------------------------------------------------------------------
\echo '--- Creating partitions for the last 8 months + 3 months of runway ---'
SELECT ops.ensure_partitions('core.wallet_ledger', now() - interval '8 months');

-- ---------------------------------------------------------------------
-- Step 2: players
-- ---------------------------------------------------------------------
INSERT INTO core.player (username, country)
SELECT 'player_' || g,
       (ARRAY['RS','DE','BR','JP','CA','NG','PT','AU'])[1 + (g % 8)]
  FROM generate_series(1, :players) g;

-- ---------------------------------------------------------------------
-- Step 3: the ledger itself.
-- Timestamps are skewed towards the present (power(random(), 2)) so the
-- recent partitions are the fat ones, like a real growing product.
--
-- The categorical columns are derived arithmetically from g rather than
-- from random(). Two reasons: the data is reproducible, and it sidesteps
-- a classic foot-gun — random() is VOLATILE, so referencing the same
-- "random" alias several times in one CASE expression re-rolls the dice
-- on every reference and silently skews the result.
-- ---------------------------------------------------------------------
SELECT setseed(0.4242);   -- reproducible amounts and timestamps

\echo '--- Inserting ledger entries ---'
INSERT INTO core.wallet_ledger
    (player_id, event_type, currency, amount, balance_after, external_ref, created_at)
SELECT
    1 + (g::bigint * 7919) % :players,
    CASE
        WHEN (g * 31) % 100 < 55 THEN 'bet'
        WHEN (g * 31) % 100 < 85 THEN 'win'
        WHEN (g * 31) % 100 < 92 THEN 'deposit'
        WHEN (g * 31) % 100 < 97 THEN 'withdrawal'
        WHEN (g * 31) % 100 < 99 THEN 'bonus'
        ELSE 'adjustment'
    END::core.ledger_event_type,
    (ARRAY['EUR','USD','BTC'])[1 + (g % 3)],
    round((random() * 500 + 0.01)::numeric, 8),
    round((random() * 10000)::numeric, 8),
    'ext-' || g,
    now() - (power(random(), 2) * 240) * interval '1 day'
FROM generate_series(1, :entries) AS g;

-- ---------------------------------------------------------------------
-- Step 4: statistics. Autovacuum will get there eventually; the planner
-- needs them NOW for the EXPLAIN demos in the next script.
-- ANALYZE on a partitioned parent takes only a SHARE UPDATE EXCLUSIVE
-- lock and does not block reads or writes — it is safe on a live ledger.
-- ---------------------------------------------------------------------
ANALYZE core.player;
ANALYZE core.wallet_ledger;

-- ---------------------------------------------------------------------
-- Step 5: the failure mode, on purpose.
-- With no default partition, a row outside every bound is rejected.
-- This is the behaviour you WANT: loud, immediate, and fixable by
-- running ops.ensure_partitions().
-- ---------------------------------------------------------------------
\echo ''
\echo '--- Deliberate failure: inserting into a month with no partition ---'
\set ON_ERROR_STOP off
INSERT INTO core.wallet_ledger
    (player_id, event_type, currency, amount, balance_after, created_at)
VALUES (1, 'deposit', 'EUR', 10, 10, now() + interval '5 years');
\set ON_ERROR_STOP on
\echo '--- (that error was expected) ---'
\echo ''

-- ---------------------------------------------------------------------
-- Where did everything land?
-- ---------------------------------------------------------------------
\echo '--- Partition inventory ---'
SELECT partition, lower_bound::date, upper_bound::date, est_rows, total_size
  FROM ops.list_partitions('core.wallet_ledger');

\echo '--- Parent totals ---'
SELECT count(*) AS rows,
       min(created_at)::date AS oldest,
       max(created_at)::date AS newest
  FROM core.wallet_ledger;
