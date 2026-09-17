-- Per-table sync state for every table the integration has attempted to
-- replicate. table_state values: Synced, Failed, Deleted, ResyncRequired,
-- ResyncInitiated, DroppedSource (Redshift Database Developer Guide,
-- SVV_INTEGRATION_TABLE_STATE). Run periodically as part of validation, or
-- after any source schema change, to confirm nothing unexpectedly dropped
-- out of Synced state.
SELECT schema_name, table_name, table_state, reason
FROM svv_integration_table_state
WHERE target_database = 'poc3_zeroetl_target';
