-- Quick health check: table_state -> count, across all replicated tables.
-- Prefer this over check_sync_state.sql (the per-table dump) for routine
-- checks — a healthy integration returns exactly one row: Synced, matching
-- the full in-scope table count.
SELECT table_state, count(*) AS table_count
FROM svv_integration_table_state
WHERE target_database = 'poc3_zeroetl_target'
GROUP BY table_state;
