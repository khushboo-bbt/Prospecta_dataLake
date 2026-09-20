# Demo Guide — POC1 / POC2 / POC3

Command-by-command runbook for demoing what's built so far on all three POCs.
Power BI is **not** included in any POC yet — it's blocked on client answers to
[poc_powerbi_questions.md](poc_powerbi_questions.md) (license, gateway hosting,
auth method, report content). Everything below proves the data layer: source →
target movement, schema, and querying, for each POC independently.

Real resource identifiers below are from the live sandbox account
(`448049790823`, `ap-southeast-1`) as of this writing — re-run the `terraform
output` command shown at the top of each POC if anything has since changed.

## Before you start

```powershell
# Confirm you're on a profile with read access to Redshift Data API, DMS, Glue, Athena, S3
aws sts get-caller-identity

# If using SSO and the session expired
aws sso login --profile <your-profile>
```

All three POCs share the sandbox VPC/foundation (`terraform/datalake-poc-foundation`).
Redshift Serverless (POC1 and POC3) and the source RDS instance are **not publicly
accessible** — for live SQL demos use the **Redshift Data API** (`aws redshift-data`,
works from your laptop, no VPN/bastion needed — it's a control-plane call) or the
AWS Console's **Redshift Query Editor v2**. Both are used below.

---

# POC 1 — Redshift Federated Query (query-in-place, no data movement)

**Story to tell:** Redshift never copies the source data. It queries the live
Postgres replica through PgBouncer on every ad-hoc query, and BI traffic instead
hits scheduled materialized views — so the primary database is never touched.

## 1. Show the pieces exist

```powershell
cd terraform\poc1-federated-query
terraform output
```

Key outputs to point at on screen:

| Output | Value |
|---|---|
| `analytics_replica_endpoint` | `datalake-poc1-analytics-replica.cngueiamkfk5.ap-southeast-1.rds.amazonaws.com` |
| `pgbouncer_private_dns_name` | `pgbouncer.datalake-poc1.internal` |
| `redshift_workgroup_endpoint` | `datalake-poc1-workgroup.448049790823.ap-southeast-1.redshift-serverless.amazonaws.com` |
| `redshift_federated_query_role_arn` | `arn:aws:iam::448049790823:role/datalake-poc1-redshift-federated-query` |

## 2. Prove the read replica is live and replicating from the source

```powershell
aws rds describe-db-instances `
  --db-instance-identifier datalake-poc1-analytics-replica `
  --query "DBInstances[0].{Status:DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier:ReadReplicaSourceDBInstanceIdentifier,ReplicaLag:StatusInfos}"
```

`ReadReplicaSourceDBInstanceIdentifier` should show `postgreslt` — the actual
source instance.

## 3. Prove PgBouncer is up (the only thing that ever opens a backend connection to the replica)

```powershell
aws ecs list-tasks --cluster datalake-poc1-cluster --service-name datalake-poc1-pgbouncer
aws ecs describe-services --cluster datalake-poc1-cluster --services datalake-poc1-pgbouncer `
  --query "services[0].{Running:runningCount,Desired:desiredCount}"
```

## 4. Show the external schema + materialized views (schema demo)

```powershell
aws redshift-data execute-statement `
  --workgroup-name datalake-poc1-workgroup `
  --database poc1_federated_query `
  --sql "SELECT schemaname, tablename FROM pg_tables WHERE schemaname = 'bi' ORDER BY tablename;"
```

Grab the `Id` from the response, then:

```powershell
aws redshift-data get-statement-result --id <statement-id-from-above>
```

You should see the 9 materialized views built in [sql/03_materialized_views.sql](terraform/poc1-federated-query/sql/03_materialized_views.sql):
`change_request_header_mv`, `chng_1_487809_mv`, `crud_metadata_mdo_mv`,
`crud_next_mdo_number_mv`, `crud_table_mapping_mv`, `databasechangelog_mv`,
`databasechangeloglock_mv`, `dyn_1_487809_mv`, `mdo_guardrail_properties_mv`.

## 5. Query the data (proves rows are actually reachable end to end)

```powershell
aws redshift-data execute-statement `
  --workgroup-name datalake-poc1-workgroup `
  --database poc1_federated_query `
  --sql "SELECT count(*) FROM bi.change_request_header_mv;"

aws redshift-data execute-statement `
  --workgroup-name datalake-poc1-workgroup `
  --database poc1_federated_query `
  --sql "SELECT * FROM bi.change_request_header_mv LIMIT 10;"
```

## 6. Prove predicate pushdown (the actual point of federated query)

```powershell
aws redshift-data execute-statement `
  --workgroup-name datalake-poc1-workgroup `
  --database poc1_federated_query `
  --sql "EXPLAIN SELECT * FROM ext_adhoc.change_request_header WHERE crnumber = '<some-known-value>';"
```

In the plan output, point out the filter appearing in the **remote (Postgres-side)**
portion of the plan — this is what proves the WHERE clause runs on the source,
not after Redshift pulls the whole table across.

## 7. Refresh a materialized view live (shows the MV isn't static)

```powershell
aws redshift-data execute-statement `
  --workgroup-name datalake-poc1-workgroup `
  --database poc1_federated_query `
  --sql "REFRESH MATERIALIZED VIEW bi.change_request_header_mv;"
```

**Not built yet (flag if asked):** scheduled auto-refresh (EventBridge Scheduler),
covering indexes on the replica, concurrency load test, Power BI connection.

---

# POC 2 — AWS DMS → S3 landing → Glue/Iceberg curation → Athena

**Story to tell:** DMS does a full load + continuous CDC from Postgres straight
into S3 as Parquet. A Glue crawler catalogs the raw landing zone; a scheduled
Glue Spark job merges/dedupes it into curated Apache Iceberg tables, queryable
through Athena.

## 1. Show the pieces exist

```powershell
cd terraform\poc2-dms-landing
terraform output
```

| Output | Value |
|---|---|
| `landing_bucket_name` | `datalake-poc2-landing-448049790823` |
| `replication_config_arn` | `arn:aws:dms:ap-southeast-1:448049790823:replication-config:datalake-poc2-full-load-cdc` |
| `glue_database_name` (raw) | `datalake_poc2` |
| `iceberg_database_name` (curated) | `datalake_poc2_curated` |
| `athena_workgroup_name` | `datalake-poc2-workgroup` |
| `iceberg_merge_job_name` | `datalake-poc2-iceberg-merge` |

In-scope table set (client-confirmed, schema `167597`, 9 tables with data —
same subset used across all three POCs so comparisons use identical data):
`change_request_header`, `chng_1_487809`, `crud_metadata_mdo`,
`crud_next_mdo_number`, `crud_table_mapping`, `databasechangelog`,
`databasechangeloglock`, `dyn_1_487809`, `mdo_guardrail_properties`.

## 2. Prove replication is running (migration status)

```powershell
aws dms describe-replications `
  --filters Name=replication-config-arn,Values=arn:aws:dms:ap-southeast-1:448049790823:replication-config:datalake-poc2-full-load-cdc `
  --query "Replications[0].{Status:Status,Stop:StopReason}"

aws dms describe-table-statistics `
  --replication-config-arn arn:aws:dms:ap-southeast-1:448049790823:replication-config:datalake-poc2-full-load-cdc `
  --query "TableStatistics[].{Table:TableName,State:TableState,FullLoadRows:FullLoadRows,Inserts:Inserts,Updates:Updates,Deletes:Deletes}"
```

`TableState: Table completed` + non-zero `FullLoadRows` per table proves the
initial migration landed; ongoing `Inserts`/`Updates` prove CDC is live.

## 3. Prove the raw Parquet landed in S3 (data migrated, schema-on-read)

```powershell
aws s3 ls s3://datalake-poc2-landing-448049790823/167597/ --recursive | Select-Object -First 20
```

Expect `LOAD*.parquet` (full load) followed by date-partitioned CDC files
(`YYYY/MM/DD/...`) as the demo/source keeps writing.

## 4. Run the Glue crawler (schema discovery demo)

```powershell
aws glue start-crawler --name datalake-poc2-crawler
aws glue get-crawler --name datalake-poc2-crawler --query "Crawler.State"
```

Then show the catalog it produced:

```powershell
aws glue get-tables --database-name datalake_poc2 --query "TableList[].Name"
aws glue get-table --database-name datalake_poc2 --name change_request_header `
  --query "Table.StorageDescriptor.Columns"
```

## 5. Query the raw landing zone via Athena (querying demo)

```powershell
aws athena start-query-execution `
  --query-string "SELECT * FROM datalake_poc2.change_request_header LIMIT 10;" `
  --work-group datalake-poc2-workgroup `
  --query-execution-context Database=datalake_poc2
```

Grab `QueryExecutionId`, then:

```powershell
aws athena get-query-results --query-execution-id <id-from-above>
```

## 6. Run the Iceberg merge job live (curation demo)

```powershell
aws glue start-job-run --job-name datalake-poc2-iceberg-merge
aws glue get-job-runs --job-name datalake-poc2-iceberg-merge --max-results 1 `
  --query "JobRuns[0].{State:JobRunState,Started:StartedOn}"
```

This is normally on a schedule (`terraform output iceberg_merge_schedule_rule`)
but running it on demand makes a good live demo beat.

## 7. Query the curated Iceberg table (proves dedup/merge worked)

```powershell
aws athena start-query-execution `
  --query-string "SELECT count(*) FROM datalake_poc2_curated.change_request_header;" `
  --work-group datalake-poc2-workgroup `
  --query-execution-context Database=datalake_poc2_curated

aws athena start-query-execution `
  --query-string "SELECT crnumber, moduleid, count(*) AS versions FROM datalake_poc2_curated.change_request_header GROUP BY crnumber, moduleid HAVING count(*) > 1;" `
  --work-group datalake-poc2-workgroup `
  --query-execution-context Database=datalake_poc2_curated
```

Second query returning **zero rows** is the actual proof point: the curated
Iceberg table is deduped by primary key (`crnumber, moduleid`), unlike the raw
landing table which can have multiple LOAD+CDC copies of the same row.

## 8. Prove Iceberg's own history/snapshots (a nice "yes it's Iceberg" beat)

```powershell
aws athena start-query-execution `
  --query-string "SELECT * FROM \"datalake_poc2_curated\".\"change_request_header\$snapshots\" ORDER BY committed_at DESC LIMIT 5;" `
  --work-group datalake-poc2-workgroup `
  --query-execution-context Database=datalake_poc2_curated
```

**Not built yet (flag if asked):** Lake Formation fine-grained access
segregation (bucket/prefix level exists; column/row-level not scoped), CDC
CloudWatch alarms wiring confirmation live, Power BI/Athena connection for BI
users (only the `curated_reader` IAM user exists for this, no report yet).

---

# POC 3 — RDS → Redshift Zero-ETL Integration

**Story to tell:** No DMS, no Glue, no pipeline code at all — AWS manages the
replication end to end (WAL read → automatic backfill → seconds-level CDC).
Two independent failure-detection paths exist because RDS publishes no
integration metrics to CloudWatch on its own.

## 1. Show the pieces exist

```powershell
cd terraform\poc3-zeroetl
terraform output
```

| Output | Value |
|---|---|
| `integration_id` | `arn:aws:rds:ap-southeast-1:448049790823:integration:625b8798-9fff-48bc-9754-f1b76a3eae41` |
| `redshift_workgroup_endpoint` | `datalake-poc3-workgroup.448049790823.ap-southeast-1.redshift-serverless.amazonaws.com` |
| `poller_lambda_name` | `datalake-poc3-zero-etl-poller` |

## 2. Prove the integration is active (migration status)

```powershell
aws rds describe-integrations `
  --integration-identifier arn:aws:rds:ap-southeast-1:448049790823:integration:625b8798-9fff-48bc-9754-f1b76a3eae41 `
  --query "Integrations[0].{Status:Status,Source:SourceArn,Target:TargetArn}"
```

Expect `Status: active`.

## 3. Show per-table sync state (schema + migration proof, 198 tables)

```powershell
aws redshift-data execute-statement `
  --workgroup-name datalake-poc3-workgroup `
  --database poc3_zeroetl_target `
  --sql "SELECT table_state, count(*) AS table_count FROM svv_integration_table_state WHERE target_database = 'poc3_zeroetl_target' GROUP BY table_state;"
```

```powershell
aws redshift-data get-statement-result --id <statement-id-from-above>
```

Healthy state: one row, `Synced`, `198`. (Validation history: 196/198 on first
pass, 198/198 after the capacity fix documented in
[CAPACITY_FINDINGS.md](terraform/poc3-zeroetl/CAPACITY_FINDINGS.md) — mention this
if asked "did everything sync cleanly the first time?": it didn't, and here's
the root cause and fix, which is a stronger story than pretending it was clean.)

## 4. Query the replicated data directly (querying demo, read-only target DB)

```powershell
aws redshift-data execute-statement `
  --workgroup-name datalake-poc3-workgroup `
  --database poc3_zeroetl_target `
  --sql "SELECT count(*) FROM \"167597\".\"change_request_header\";"
```

## 5. Query the BI-facing consumer view (cross-database query demo)

```powershell
aws redshift-data execute-statement `
  --workgroup-name datalake-poc3-workgroup `
  --database poc3_consumer `
  --sql "SELECT * FROM bi.change_request_header_v LIMIT 10;"
```

This view lives in a **separate** database (`poc3_consumer`) from the
integration's read-only target (`poc3_zeroetl_target`) and reaches across via
Redshift's cross-database query — a deliberate design point worth calling out
(the destination DB an integration creates is read-only, so views/MVs can't
live there).

## 6. Live latency proof — insert on source, watch it appear in Redshift (the best demo beat)

```powershell
cd terraform\poc3-zeroetl
.\measure_latency.ps1
```

This script inserts a timestamped row on the source and polls Redshift until
it's visible, then reports the measured latency. Prior runs: ~19-21s typical.
Great to run live and narrate while it polls.

## 7. Show schema-change propagation (optional, if you want to demo live DDL)

Zero-ETL propagates `ADD COLUMN` / `RENAME COLUMN` / `DROP COLUMN` on the
source automatically with no resync — confirmed during validation. Only do
this live if you have a safe scratch table, not on `167597` production-shaped
data.

## 8. Show the sync-failure detection path (the two-independent-paths story)

```powershell
aws lambda invoke --function-name datalake-poc3-zero-etl-poller poller-output.json
Get-Content poller-output.json

aws cloudwatch get-metric-data `
  --metric-data-queries '[{"Id":"m1","MetricStat":{"Metric":{"Namespace":"Custom/ZeroETL","MetricName":"UnsyncedTableCount"},"Period":300,"Stat":"Maximum"}}]' `
  --start-time (Get-Date).AddHours(-1).ToString("yyyy-MM-ddTHH:mm:ss") `
  --end-time (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
```

Explain: path 1 is EventBridge on the integration's own state-change events
(fires on AWS-detected failures); path 2 is this poller, which catches the
gap AWS itself flagged — a table can silently stop syncing without the
integration raising an error, so a periodic direct check of
`svv_integration_table_state` is required independent of AWS's own alerting.

## 9. Failed-table detail query (only if any table isn't Synced)

```powershell
aws redshift-data execute-statement `
  --workgroup-name datalake-poc3-workgroup `
  --database poc3_zeroetl_target `
  --sql "SELECT trim(schema_name), trim(table_name), trim(reason) FROM svv_integration_table_state WHERE target_database = 'poc3_zeroetl_target' AND table_state = 'Failed';"
```

**Not built yet (flag if asked):** BI role grants on the consumer view
(commented out pending the Power BI service account), major-version-upgrade
runbook, as-built architecture diagram, Power BI connection.

---

# Closing the demo — what's common across all three

- All three POCs read from the **same 9-table, schema-`167597` subset** of
  `postgreslt` / `mdo-core-crud`, specifically so a side-by-side comparison
  (cost, latency, operational complexity) is apples-to-apples.
- The one piece common to all three and **not yet done**: Power BI. Point to
  [poc_powerbi_questions.md](poc_powerbi_questions.md) — license tier, gateway
  hosting decision (client VM vs. an EC2 gateway we'd provision), Redshift/Athena
  auth method, and report content are all still open client questions blocking
  this, not implementation work outstanding on our side.
