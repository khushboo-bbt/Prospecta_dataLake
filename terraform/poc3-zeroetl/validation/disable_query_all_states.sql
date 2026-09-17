-- Restores the default (queries only see confirmed-Synced data). Run this
-- after any debugging session that used enable_query_all_states.sql.
ALTER DATABASE poc3_zeroetl_target INTEGRATION SET QUERY_ALL_STATES FALSE;
