-- Run against the Redshift Serverless workgroup, as the namespace admin
-- user, connected to the CONSUMER database this time (var.consumer_db_name,
-- default "poc3_consumer" — the namespace's own db_name, created by
-- redshift.tf, not by 01_create_target_database.sql).
--
-- Cross-database query references the read-only destination database
-- created in 01_create_target_database.sql via three-part notation
-- (<database>.<schema>.<table>). enable_case_sensitive_identifier is "true"
-- on this workgroup (required by the integration itself — redshift.tf), so
-- the schema/table names below must be double-quoted to match the source's
-- exact case.
--
-- change_request_header is the same representative table poc1's
-- mv_refresh.tf and poc2's iceberg_table_configs already use, so all three
-- POCs' comparison (SOW deliverable D11) reads from identical data end to
-- end, not just at the same schema level.

CREATE SCHEMA IF NOT EXISTS bi;

-- WITH NO SCHEMA BINDING is required (not optional) for any view that
-- references another database via cross-database query — Redshift rejects
-- a normal (schema-bound) view outright: "External tables are not supported
-- in views." A late-binding view defers resolving the referenced table
-- until query time instead of at CREATE VIEW time.
CREATE VIEW bi.change_request_header_v AS
SELECT *
FROM poc3_zeroetl_target."167597"."change_request_header"
WITH NO SCHEMA BINDING;

-- BI users are granted here, on the view only — never given direct access
-- to poc3_zeroetl_target (mirrors poc1's "grant to materialized views only,
-- never the external schema" control). See sql/03_powerbi_reader_role.sql
-- for the actual role/user creation and grant.

-- Validate the cross-database read is actually live before building the
-- Power BI report on top of it:
--   SELECT count(*) FROM bi.change_request_header_v;
