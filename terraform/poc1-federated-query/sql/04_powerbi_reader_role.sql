-- Run against the Redshift Serverless workgroup (terraform output:
-- redshift_workgroup_endpoint), database poc1_federated_query, as the
-- namespace admin user, after 03_materialized_views.sql has created the
-- bi_reader role.
--
-- Client-confirmed auth method for Power BI (poc_powerbi_questions.md,
-- question 4): DB username/password, not IAM. This user is what the Power BI
-- data source connection (configured on the shared gateway - see
-- ../../powerbi-gateway/README.md) authenticates as.
--
-- Grants nothing directly - bi_reader (03_materialized_views.sql) is already
-- the access-control boundary, scoped to SELECT on the bi schema's
-- materialized views only. This is a one-line GRANT ROLE, exactly as
-- anticipated when bi_reader was created.
--
-- Replace <powerbi_reader_password> with the value configured as this data
-- source's credential in Power BI Service - entered directly there, not
-- stored in Secrets Manager or any other AWS resource this module manages.
-- Redshift password rules: 8-64 characters, at least one uppercase, one
-- lowercase, one digit; must not contain '\', '"', ''', @, or a space.

CREATE USER powerbi_reader WITH PASSWORD '<powerbi_reader_password>';
GRANT ROLE bi_reader TO powerbi_reader;
