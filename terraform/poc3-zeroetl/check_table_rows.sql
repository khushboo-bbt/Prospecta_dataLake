SELECT trim(schema_name) AS schema_name, trim(table_name) AS table_name, table_rows, table_size
FROM svv_integration_table_state
WHERE target_database = 'poc3_zeroetl_target'
  AND trim(table_name) = 'change_request_header';
