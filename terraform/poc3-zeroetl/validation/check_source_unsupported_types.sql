-- Run against the SOURCE (postgreslt/mdo-core-crud), not Redshift. Flags
-- columns using data types zero-ETL doesn't support (geometry/geography
-- types; text/bytea over 64KB isn't caught here since that's a per-VALUE
-- limit, not a per-column type — see the Failed-table reason text instead
-- for that case, e.g. via check_failed_tables.sql).
SELECT
    c.table_name,
    c.column_name,
    c.udt_name
FROM information_schema.columns c
WHERE c.table_schema = '167597'
  AND c.udt_name IN ('geometry', 'geography', 'point', 'line', 'lseg', 'box', 'path', 'polygon', 'circle', 'xml')
ORDER BY c.table_name, c.column_name;
