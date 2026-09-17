SELECT
    c.table_name,
    c.column_name,
    c.udt_name
FROM information_schema.columns c
WHERE c.table_schema = '167597'
  AND c.udt_name IN ('geometry', 'geography', 'point', 'line', 'lseg', 'box', 'path', 'polygon', 'circle', 'xml')
ORDER BY c.table_name, c.column_name;
