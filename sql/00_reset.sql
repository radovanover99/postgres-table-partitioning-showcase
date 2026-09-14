-- =====================================================================
-- 00_reset.sql — wipe the demo so you can run the showcase again
-- Safe to run on an empty database.
-- =====================================================================
\set ON_ERROR_STOP on
SET timezone = 'UTC';

DROP SCHEMA IF EXISTS reporting CASCADE;
DROP SCHEMA IF EXISTS archive   CASCADE;
DROP SCHEMA IF EXISTS core      CASCADE;
DROP SCHEMA IF EXISTS legacy    CASCADE;
DROP SCHEMA IF EXISTS ops       CASCADE;

\echo 'Demo objects dropped.'
