-- Run against the Redshift Serverless workgroup, after 02_external_schema.sql.
-- One example per representative table — repeat per table in the agreed
-- in-scope subset. AUTO REFRESH keeps the MV current without a separate
-- scheduler; switch to a manual REFRESH on a schedule (e.g. via EventBridge
-- + the Redshift Data API) if a fixed refresh cadence is preferred over
-- Redshift's own auto-refresh heuristic.

CREATE SCHEMA IF NOT EXISTS bi;

CREATE MATERIALIZED VIEW bi.<table_name>_mv
AUTO REFRESH YES
AS
SELECT *
FROM ext_mv_refresh.<table_name>;

-- BI users/roles get SELECT on the materialized view only — never on
-- ext_mv_refresh or ext_adhoc. This is what actually keeps concurrent BI
-- query volume off the source: every BI query resolves against this MV, and
-- only the scheduled refresh itself (and ad-hoc analysis via ext_adhoc, used
-- sparingly/interactively) ever executes a federated query.
GRANT USAGE ON SCHEMA bi TO <bi_role>;
GRANT SELECT ON bi.<table_name>_mv TO <bi_role>;

-- Validate predicate pushdown before treating a query as representative:
--   EXPLAIN SELECT * FROM ext_adhoc.<table_name> WHERE <predicate>;
-- Look for the filter appearing in the remote (Postgres-side) portion of the
-- plan, not applied after the full table is pulled into Redshift. Where a
-- join restriction won't push down, encapsulate it in a Postgres view on the
-- replica instead (SOW: "encapsulate the join in a PostgreSQL view so the
-- restriction is applied at source") — schema-specific, not scripted here.
