SELECT
    t.table_name,
    EXISTS (
        SELECT 1 FROM information_schema.table_constraints tc
        WHERE tc.table_schema = t.table_schema
          AND tc.table_name = t.table_name
          AND tc.constraint_type = 'PRIMARY KEY'
    ) AS has_primary_key
FROM information_schema.tables t
WHERE t.table_schema = '167597'
  AND t.table_type = 'BASE TABLE'
ORDER BY t.table_name;
