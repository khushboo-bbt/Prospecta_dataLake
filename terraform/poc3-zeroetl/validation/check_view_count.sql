-- Confirms the Power BI-facing consumer view (sql/02_consumer_views.sql) is
-- actually returning data, not just successfully created. Run against
-- database poc3_consumer.
SELECT count(*) AS row_count FROM bi.change_request_header_v;
