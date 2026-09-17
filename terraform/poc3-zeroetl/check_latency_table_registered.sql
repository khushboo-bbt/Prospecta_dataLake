SELECT trim(schema_name) AS schema_name, trim(table_name) AS table_name, trim(table_state) AS table_state
FROM svv_integration_table_state
WHERE target_database = 'poc3_zeroetl_target'
  AND trim(table_name) = 'zero_etl_latency_test';
