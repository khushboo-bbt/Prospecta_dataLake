-- Does Redshift's OWN storage catalog show physical blocks consumed for these
-- tables? This is independent of anything the integration reports about
-- itself: size/tbl_rows here come from Redshift's storage layer, not from
-- integration metadata. If size = 0, nothing physically landed.
SELECT "table", tbl_rows, size, unsorted, stats_off
FROM svv_table_info
WHERE "schema" = '167597'
ORDER BY size DESC
LIMIT 20;
