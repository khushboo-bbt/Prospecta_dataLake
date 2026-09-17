SELECT table_state, count(*) AS table_count
FROM svv_integration_table_state
WHERE target_database = 'poc3_zeroetl_target'
GROUP BY table_state;
