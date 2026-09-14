-- =====================================================================
-- 99_teardown.sql — remove everything the showcase created.
-- =====================================================================
\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS reporting CASCADE;
DROP SCHEMA IF EXISTS archive   CASCADE;
DROP SCHEMA IF EXISTS core      CASCADE;
DROP SCHEMA IF EXISTS legacy    CASCADE;
DROP SCHEMA IF EXISTS ops       CASCADE;

\echo 'Showcase removed.'
