SELECT trim(schema_name) AS schema_name, trim(table_name) AS table_name, trim(reason) AS reason
FROM svv_integration_table_state
WHERE target_database = 'poc3_zeroetl_target'
  AND table_state = 'Failed';
