-- Run against the Redshift Serverless workgroup (terraform output:
-- redshift_workgroup_endpoint), database poc3_consumer (NOT
-- poc3_zeroetl_target - that's the read-only integration destination; the
-- bi schema/view live in the consumer database, see 02_consumer_views.sql),
-- as the namespace admin user.
--
-- Same DB username/password auth pattern as poc1-federated-query's
-- sql/04_powerbi_reader_role.sql (poc_powerbi_questions.md, question 4).
-- Grants nothing beyond the one consumer view - never on
-- poc3_zeroetl_target directly, mirroring poc1's "BI role never touches the
-- federated/external schema" boundary.
--
-- Replace <powerbi_reader_password> with the value configured as this data
-- source's credential in Power BI Service - entered directly there, not
-- stored in Secrets Manager or any other AWS resource this module manages.
-- Redshift password rules: 8-64 characters, at least one uppercase, one
-- lowercase, one digit; must not contain '\', '"', ''', @, or a space.

CREATE ROLE bi_reader;
GRANT USAGE ON SCHEMA bi TO ROLE bi_reader;
GRANT SELECT ON bi.change_request_header_v TO ROLE bi_reader;

CREATE USER powerbi_reader WITH PASSWORD '<powerbi_reader_password>';
GRANT ROLE bi_reader TO powerbi_reader;
