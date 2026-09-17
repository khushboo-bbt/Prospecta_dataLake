-- Lets ad-hoc queries read tables that aren't fully Synced (mid-resync,
-- ResyncInitiated, etc.) instead of erroring with "table is not available
-- for querying right now". Needed for debugging/testing; turn back off
-- (disable_query_all_states.sql) once done — production/BI queries should
-- only ever see confirmed-Synced data.
ALTER DATABASE poc3_zeroetl_target INTEGRATION SET QUERY_ALL_STATES TRUE;
