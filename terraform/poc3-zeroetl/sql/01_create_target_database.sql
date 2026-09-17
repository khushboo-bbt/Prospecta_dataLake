-- Run against the Redshift Serverless workgroup (terraform output:
-- redshift_workgroup_endpoint), as the namespace admin user, connected to
-- the DEFAULT/admin database (not the consumer database yet — this database
-- doesn't exist until this script runs).
--
-- Prerequisite: the integration must be Active first —
--   aws rds describe-integrations --integration-identifier <integration_id output>
-- must show Status: active before this will succeed.
--
-- <integration_id> = terraform output: integration_id
--
-- No Terraform resource exists for CREATE DATABASE ... FROM INTEGRATION (the
-- AWS provider has none — confirmed via `terraform providers schema -json`),
-- so this is a manual, one-time step per the AWS Redshift Management Guide,
-- "Creating destination databases in Amazon Redshift". For an RDS for
-- PostgreSQL source, the DATABASE clause naming the source's named database
-- is required (unlike Aurora MySQL/RDS MySQL sources, which omit it).
--
-- "mdo-core-crud" is quoted because Redshift identifiers containing a hyphen
-- must be double-quoted.

CREATE DATABASE poc3_zeroetl_target
FROM INTEGRATION '<integration_id>'
DATABASE "mdo-core-crud";

-- Once created, this database is READ-ONLY (SOW: "The destination Redshift
-- database is read-only, so consumer-facing views and materialised views
-- are built in a separate Redshift analytics database" — see
-- 02_consumer_views.sql). Only the integration itself can write to it; DDL
-- and read-only queries are all this module's admin user can run against it
-- directly.
--
-- Confirm per-table sync state before building anything on top of this:
--   SELECT schema_name, table_name, table_state, reason
--   FROM svv_integration_table_state
--   WHERE target_database = 'poc3_zeroetl_target';
-- Every in-scope table should show table_state = 'Synced'. Any table that
-- doesn't must be identified with its cause documented, per the SOW's
-- Functional Threshold ("Any table that did not replicate is identified,
-- with the cause documented").
