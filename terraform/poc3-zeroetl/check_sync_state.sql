SELECT schema_name, table_name, table_state, reason
FROM svv_integration_table_state
WHERE target_database = 'poc3_zeroetl_target';
