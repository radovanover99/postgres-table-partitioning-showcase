-- =====================================================================
-- 01_schemas_and_table.sql
-- The partitioned transaction table: core.wallet_ledger
--
-- Talking points in this file:
--   1. Why range-partition a transaction table at all
--   2. Choosing the partition key and the granularity
--   3. The two constraint rules everyone trips over
--   4. The timestamptz + TimeZone trap in partition bounds
--   5. Why this demo has NO default partition
-- =====================================================================
\set ON_ERROR_STOP on

-- (4) THE TIMEZONE TRAP ------------------------------------------------
-- Partition bounds for a timestamptz column are evaluated ONCE, at DDL
-- time, using the session TimeZone. If you create partitions from a
-- laptop in Europe/Belgrade and your cron box runs in UTC, your monthly
-- boundaries land at 23:00 or 22:00 UTC and you get silent overlaps in
-- reporting. Always pin the timezone for partition DDL.
SET timezone = 'UTC';

CREATE SCHEMA IF NOT EXISTS core;       -- hot, transactional data
CREATE SCHEMA IF NOT EXISTS archive;    -- cold, detached partitions
CREATE SCHEMA IF NOT EXISTS reporting;  -- views that span hot + cold
CREATE SCHEMA IF NOT EXISTS ops;        -- partition management toolkit

-- ---------------------------------------------------------------------
-- Reference table, so we can show that foreign keys still work.
-- Since PG 12 a partitioned table may reference a regular table, and
-- since PG 12 a regular table may also reference a partitioned table.
-- ---------------------------------------------------------------------
CREATE TABLE core.player (
    player_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username    text        NOT NULL UNIQUE,
    country     char(2)     NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TYPE core.ledger_event_type AS ENUM
    ('deposit', 'withdrawal', 'bet', 'win', 'bonus', 'adjustment');

-- =====================================================================
-- (1) WHY PARTITION
--
-- This is a money ledger: append-only, queried almost exclusively by
-- "recent", and it never stops growing. Without partitioning, the only
-- way to drop old data is DELETE, which:
--     * writes a WAL record and a dead tuple for every single row,
--     * leaves bloat that autovacuum has to grind through,
--     * never returns the disk to the OS without a VACUUM FULL
--       (ACCESS EXCLUSIVE lock — a full outage on your ledger),
--     * leaves the indexes bloated too.
-- With partitioning, "delete 40 million rows" becomes a catalog update
-- that finishes in milliseconds.
--
-- (2) PARTITION KEY AND GRANULARITY
--
-- Key: created_at. Rules for a good range key:
--     * immutable after insert (never UPDATE it — an UPDATE that moves a
--       row across partitions is supported since PG 11 but it is a
--       DELETE+INSERT under the covers and it defeats HOT updates),
--     * present in essentially every query's WHERE clause, otherwise you
--       lose pruning and every query touches every partition,
--     * monotonically increasing, so old partitions go fully cold.
--
-- Granularity: MONTHLY here. Rule of thumb — aim for partitions in the
-- 1-20 GB range and keep the total partition count in the low hundreds.
-- The planner has to consider every partition at plan time, so 5,000
-- daily partitions will show up as planning-time pain long before the
-- data does.
--   * A 90-day hot window with MONTHLY partitions means you actually
--     keep 90-120 days hot, because a partition can only be archived
--     once its ENTIRE range is past the cutoff.
--   * If "exactly 90 days" matters, switch to WEEKLY (13 partitions
--     hot) or DAILY. The toolkit in 02_partition_toolkit.sql is driven
--     by a config row, so changing granularity is a one-word change.
-- =====================================================================

CREATE TABLE core.wallet_ledger (
    entry_id      bigint GENERATED ALWAYS AS IDENTITY,
    player_id     bigint                 NOT NULL,
    event_type    core.ledger_event_type NOT NULL,
    currency      char(3)                NOT NULL,
    amount        numeric(20,8)          NOT NULL,
    balance_after numeric(20,8)          NOT NULL,
    external_ref  text,
    created_at    timestamptz            NOT NULL DEFAULT now(),

    -- (3) RULE ONE: the primary key must CONTAIN the partition key.
    -- `PRIMARY KEY (entry_id)` alone is rejected:
    --     ERROR: unique constraint on partitioned table must include
    --            all partitioning columns
    -- Postgres has no global index, so it can only enforce uniqueness
    -- inside one partition. Practical consequence: entry_id is unique
    -- in practice (it comes from one sequence) but the database only
    -- guarantees (entry_id, created_at) is unique. Application code
    -- that looks a row up by entry_id alone will scan every partition —
    -- always carry created_at alongside the id.
    CONSTRAINT wallet_ledger_pkey PRIMARY KEY (entry_id, created_at),

    -- RULE TWO: same for every other UNIQUE constraint. Idempotency
    -- keys are the classic casualty. (external_ref, created_at) means
    -- the same external_ref CAN reappear in a different month — if that
    -- is unacceptable, keep the idempotency key in a small unpartitioned
    -- side table instead of pretending this constraint is global.
    CONSTRAINT wallet_ledger_external_ref_key UNIQUE (external_ref, created_at),

    CONSTRAINT wallet_ledger_player_fk
        FOREIGN KEY (player_id) REFERENCES core.player (player_id),

    CONSTRAINT wallet_ledger_amount_sane CHECK (amount <> 0)
)
PARTITION BY RANGE (created_at);

-- ---------------------------------------------------------------------
-- Indexes are declared ONCE on the parent. Postgres creates a matching
-- index on every existing partition and on every partition you add
-- later. (See 09_operations_and_monitoring.sql for how to add an index
-- to a live partitioned table WITHOUT a long ACCESS EXCLUSIVE lock.)
-- ---------------------------------------------------------------------

-- The bread-and-butter query: one player's recent ledger.
CREATE INDEX wallet_ledger_player_time_idx
    ON core.wallet_ledger (player_id, created_at DESC);

-- Operational queries: "all withdrawals in the last 24h".
CREATE INDEX wallet_ledger_type_time_idx
    ON core.wallet_ledger (event_type, created_at DESC);

-- =====================================================================
-- (5) NO DEFAULT PARTITION — a deliberate choice
--
-- A default partition looks like a safety net and behaves like a trap:
--
--   a) It silently accepts rows nobody planned for. A clock skew or a
--      backfill with a bad timestamp lands there and nothing complains.
--   b) Creating the partition that SHOULD have held those rows then
--      requires Postgres to scan the whole default partition under an
--      ACCESS EXCLUSIVE lock to prove no row belongs in the new range —
--      and it fails outright if even one row does.
--   c) ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY is NOT ALLOWED
--      on a partitioned table that has a default partition. That is the
--      one command this whole archiving strategy is built on.
--
-- The alternative is discipline, not a net: pre-create partitions well
-- ahead of time and MONITOR the runway. An INSERT with no matching
-- partition fails loudly with
--     ERROR: no partition of relation "wallet_ledger" found for row
-- which is exactly the page you want at 3am, instead of discovering
-- six months later that 400 million rows are stuck in wallet_ledger_def.
--
-- 09_operations_and_monitoring.sql has the runway alert query and the
-- recipe for digging rows back out of a default partition if your shop
-- decides to keep one anyway.
-- =====================================================================

\echo 'core.wallet_ledger created (partitioned by range on created_at, no partitions yet).'
