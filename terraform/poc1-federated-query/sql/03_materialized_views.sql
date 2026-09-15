-- Run against the Redshift Serverless workgroup (terraform output:
-- redshift_workgroup_endpoint), after 02_external_schema.sql, as the
-- namespace admin user.
--
-- One materialized view per table in the client-confirmed in-scope subset
-- (same 9 tables identified as actually containing data during POC2's
-- discovery of schema 167597 — the rest of that schema's ~198 tables are
-- empty scaffolding, not worth materializing).
--
-- No AUTO REFRESH: confirmed via testing that Redshift rejects it outright
-- for MVs defined on federated/external tables ("ERROR: Auto-refresh is not
-- supported for materialized views defined on the referenced tables") - not
-- a preference, a hard platform limitation, since Redshift has no way to
-- track incremental source-side changes on an external Postgres table the
-- way it does for native ones. These need a scheduled manual
-- REFRESH MATERIALIZED VIEW instead (EventBridge Scheduler + the Redshift
-- Data API, same pattern as poc2-dms-landing's Iceberg merge job scheduling)
-- - not yet built; a follow-up once a refresh cadence is agreed.

CREATE SCHEMA IF NOT EXISTS bi;

CREATE MATERIALIZED VIEW bi.change_request_header_mv
AS
SELECT * FROM ext_mv_refresh.change_request_header;

CREATE MATERIALIZED VIEW bi.chng_1_487809_mv
AS
SELECT * FROM ext_mv_refresh.chng_1_487809;

CREATE MATERIALIZED VIEW bi.crud_metadata_mdo_mv
AS
SELECT * FROM ext_mv_refresh.crud_metadata_mdo;

CREATE MATERIALIZED VIEW bi.crud_next_mdo_number_mv
AS
SELECT * FROM ext_mv_refresh.crud_next_mdo_number;

CREATE MATERIALIZED VIEW bi.crud_table_mapping_mv
AS
SELECT * FROM ext_mv_refresh.crud_table_mapping;

CREATE MATERIALIZED VIEW bi.databasechangelog_mv
AS
SELECT * FROM ext_mv_refresh.databasechangelog;

CREATE MATERIALIZED VIEW bi.databasechangeloglock_mv
AS
SELECT * FROM ext_mv_refresh.databasechangeloglock;

CREATE MATERIALIZED VIEW bi.dyn_1_487809_mv
AS
SELECT * FROM ext_mv_refresh.dyn_1_487809;

CREATE MATERIALIZED VIEW bi.mdo_guardrail_properties_mv
AS
SELECT * FROM ext_mv_refresh.mdo_guardrail_properties;

-- Dedicated BI-facing role: this is the actual access-control boundary.
-- Gets SELECT on the materialized views only - never on ext_mv_refresh or
-- ext_adhoc. This is what keeps concurrent BI query volume off the source
-- entirely: every BI query resolves against these MVs, and only the
-- scheduled refresh itself (plus ad-hoc analysis via ext_adhoc, used
-- sparingly/interactively, e.g. by whoever is doing analysis work directly)
-- ever executes a federated query against the replica.
--
-- No actual login user is granted this role yet - that happens once the
-- Power BI connection is set up (a later, separate step). Creating the role
-- with correct permissions now means the boundary already exists; granting
-- it to a real user later is a one-line GRANT ROLE bi_reader TO <user>.
CREATE ROLE bi_reader;
GRANT USAGE ON SCHEMA bi TO ROLE bi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA bi TO ROLE bi_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA bi GRANT SELECT ON TABLES TO ROLE bi_reader;

-- Validate predicate pushdown before treating a query as representative:
--   EXPLAIN SELECT * FROM ext_adhoc.<table_name> WHERE <predicate>;
-- Look for the filter appearing in the remote (Postgres-side) portion of the
-- plan, not applied after the full table is pulled into Redshift. Where a
-- join restriction won't push down, encapsulate it in a Postgres view on the
-- replica instead (SOW: "encapsulate the join in a PostgreSQL view so the
-- restriction is applied at source") - not needed yet, since no current BI
-- query pattern requires a cross-table join; build this only once a real
-- one does, not speculatively.
