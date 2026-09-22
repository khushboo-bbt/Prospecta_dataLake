-- Run against the analytics replica's database (terraform output:
-- analytics_replica_endpoint / var.source_db_name), not the source primary.
-- Replicas inherit the source's roles, but these two POC1-specific,
-- read-only logins should be created directly on the replica if it is not
-- writable back to the source (standard RDS async read replicas are
-- read-only, so DDL run here does not propagate to or from the primary).
--
-- Replace <mv_refresh_password> / <adhoc_password> with the same values
-- passed as TF_VAR_mv_refresh_db_password / TF_VAR_adhoc_db_password.

CREATE ROLE redshift_mv_refresh WITH LOGIN PASSWORD '<mv_refresh_password>';
CREATE ROLE redshift_adhoc WITH LOGIN PASSWORD '<adhoc_password>';

-- Client-confirmed in-scope database/schema: mdo-core-crud / 167597 (same
-- scope agreed for poc2-dms-landing).
GRANT CONNECT ON DATABASE "mdo-core-crud" TO redshift_mv_refresh, redshift_adhoc;
GRANT USAGE ON SCHEMA "167597" TO redshift_mv_refresh, redshift_adhoc;
GRANT SELECT ON ALL TABLES IN SCHEMA "167597" TO redshift_mv_refresh, redshift_adhoc;
ALTER DEFAULT PRIVILEGES IN SCHEMA "167597" GRANT SELECT ON TABLES TO redshift_mv_refresh, redshift_adhoc;

-- Only needed if these two logins ever require different timeouts than the
-- instance-wide values set via the replica's parameter group
-- (aws_db_parameter_group.analytics_replica in replica.tf).
-- ALTER ROLE redshift_mv_refresh SET statement_timeout = '300000';
-- ALTER ROLE redshift_adhoc SET statement_timeout = '300000';
