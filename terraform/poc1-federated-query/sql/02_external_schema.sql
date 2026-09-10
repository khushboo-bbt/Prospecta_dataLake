-- Run against the Redshift Serverless workgroup (terraform output:
-- redshift_workgroup_endpoint), as the namespace admin user.
--
-- Two external schemas, one per use case, so each can be granted to BI users
-- independently and so a runaway ad-hoc query never shares a connection pool
-- slot with the scheduled MV refresh (both still funnel through the same
-- PgBouncer NLB — terraform output: pgbouncer_nlb_dns_name — which is the
-- only thing that ever opens a backend connection to the replica).
--
-- <redshift_federated_query_role_arn> = terraform output: redshift_federated_query_role_arn
-- <mv_refresh_db_secret_arn>          = terraform output: mv_refresh_db_secret_arn
-- <adhoc_db_secret_arn>               = terraform output: adhoc_db_secret_arn
-- <pgbouncer_nlb_dns_name>            = terraform output: pgbouncer_nlb_dns_name

CREATE EXTERNAL SCHEMA ext_mv_refresh
FROM POSTGRES
DATABASE '<source_db_name>'
SCHEMA '<in_scope_schema>'
URI '<pgbouncer_nlb_dns_name>'
PORT 6432
IAM_ROLE '<redshift_federated_query_role_arn>'
SECRET_ARN '<mv_refresh_db_secret_arn>';

CREATE EXTERNAL SCHEMA ext_adhoc
FROM POSTGRES
DATABASE '<source_db_name>'
SCHEMA '<in_scope_schema>'
URI '<pgbouncer_nlb_dns_name>'
PORT 6432
IAM_ROLE '<redshift_federated_query_role_arn>'
SECRET_ARN '<adhoc_db_secret_arn>';

-- BI users are never granted here directly — see 03_materialized_views.sql.
-- This is the primary control that keeps every BI query off the source:
-- BI roles get USAGE on the *materialized view* schema only, never on
-- ext_mv_refresh / ext_adhoc.
