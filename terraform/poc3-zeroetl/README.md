# POC 3 — Amazon RDS to Amazon Redshift Zero-ETL Integration

Scope (SOW "POC 3 — Amazon RDS to Amazon Redshift Zero-ETL Integration"): the AWS-managed
Zero-ETL integration reads the source write-ahead log and performs an automatic initial backfill
followed by seconds-level replication, with table-level data filtering. There is no DMS, no Glue
and no pipeline code. The destination Redshift database is read-only, so consumer-facing views
and materialised views are built in a separate Redshift analytics database. Two independent
sync-failure detection paths are required, since Amazon RDS publishes no integration metrics to
CloudWatch and a table can stop synchronising without the integration itself raising an error.

This module assumes the AWS Sandbox Foundation (`terraform/datalake-poc-foundation` — VPC,
subnets, route tables) already exists. It does not create or modify the source RDS instance
(`postgreslt`) itself, including its parameter group — that lives entirely in
`terraform/poc2-dms-landing` (see "Manual step" below for why).

## What this creates

- A customer-managed KMS key (`kms.tf`) — the Redshift and RDS service principals both need
  `kms:CreateGrant` on it, not just Decrypt, since Redshift creates its own grant when the
  integration is created.
- A Redshift Serverless namespace + workgroup (`redshift.tf`, base 8 RPU), with
  `enable_case_sensitive_identifier = "true"` — required by the integration itself, unlike POC1's
  workgroup. **Not** the resource policy authorising `postgreslt` as an inbound integration source —
  that's a manual step, see below.
- The `aws_rds_integration` itself (`integration.tf`), scoped to the client-confirmed schema
  `167597` via `data_filter`.
- A sync-failure poller Lambda (`lambda.tf`, `lambda/zero_etl_poller.py`) that queries
  `SVV_INTEGRATION_TABLE_STATE` via the Redshift Data API on a 5-minute schedule and publishes a
  `Custom/ZeroETL` / `UnsyncedTableCount` CloudWatch metric — the SOW's second detection path.
- Two EventBridge rules (`eventbridge.tf`): one on the integration's own state-change events
  (pattern confirmed against a real captured Warning-severity event — see the resource's
  comment), one on the poller's schedule. Both ultimately notify the same SNS topic
  (`monitoring.tf`) as the CloudWatch alarms.

## Manual step: extend the shared parameter group and coordinate the reboot

This module has no `aws_db_parameter_group` of its own. The zero-ETL requirements
(`rds.replica_identity_full`, `session_replication_role`, `max_slot_wal_keep_size`, plus the
existing `rds.logical_replication`/`max_wal_senders`/`max_replication_slots`/`wal_sender_timeout`)
were added directly to `poc2-dms-landing`'s `aws_db_parameter_group.logical_replication` instead
of creating a second, competing one here.

Why: only one parameter group can be attached to `postgreslt` at a time. An earlier version of
this plan gave POC3 its own group, which would have forced POC2's DMS CDC and POC3's Zero-ETL
into separate, mutually exclusive attach windows — incompatible with the SOW's final side-by-side
comparison (deliverable D11), which needs both operating concurrently. Extending POC2's
already-applied group instead means one attach, one reboot, and both POCs synchronising against
the same instance state at once.

**Trade-off to watch:** `rds.replica_identity_full` is instance-wide, not per-table — it increases
WAL volume for all ~28 databases on `postgreslt`, including POC2's own CDC traffic. Watch POC2's
`TransactionLogsDiskUsage`/`ReplicationSlotDiskUsage`/`FreeStorageSpace` alarms after the reboot
below.

Apply and reboot from **`terraform/poc2-dms-landing`**, not from here:

```
cd ../poc2-dms-landing
terraform apply   # picks up the new parameter blocks

aws rds modify-db-instance \
  --db-instance-identifier <source_db_instance_identifier> \
  --db-parameter-group-name $(terraform output -raw parameter_group_name) \
  --apply-immediately

aws rds reboot-db-instance \
  --db-instance-identifier <source_db_instance_identifier>
```

Confirm after reboot:

```
aws rds describe-db-parameters \
  --db-parameter-group-name $(terraform output -raw parameter_group_name) \
  --query "Parameters[?ParameterName=='rds.replica_identity_full' || ParameterName=='rds.logical_replication']"
```

Both must show `ParameterValue: 1` and `ApplyStatus: in-sync`. If POC2's group was already
attached and rebooted before this change, only `rds.replica_identity_full` is new and
`pending-reboot` — the others stay `in-sync` from POC2's earlier reboot.

## Manual step: authorise the source RDS instance on the namespace

`aws_redshiftserverless_resource_policy` isn't declared in Terraform for this namespace —
`hashicorp/aws` 5.100.0 has a bug where the provider can't read this resource back after writing
it (`GetResourcePolicy` always returns `Statement` as a JSON array, matching AWS's own documented
sample, but the provider's Go model expects a single object, so every subsequent `plan`/`refresh`
fails with `cannot unmarshal array into Go struct field resourcePolicyDoc.Statement`). This
reproduces regardless of what shape is submitted, so it can't be worked around from the Terraform
side. Set (or re-set, if this namespace is ever recreated) via the AWS CLI instead:

```
aws redshift-serverless put-resource-policy \
  --resource-arn <redshift_namespace_arn output> \
  --policy file://resource-policy.json \
  --region ap-southeast-1
```

`resource-policy.json` in this directory has the exact two-statement document (AWS Redshift
Management Guide, "Configure authorization for your Amazon Redshift data warehouse") with real
account/namespace/source values already filled in. Confirm it's in place before applying
`integration.tf`:

```
aws redshift-serverless get-resource-policy --resource-arn <redshift_namespace_arn output> --region ap-southeast-1
```

## Configure

```
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — vpc_id / private_subnet_ids / vpc_cidr come from
# `terraform output` in datalake-poc-foundation
```

No `TF_VAR_*` password export is needed — POC3 authenticates to Redshift via the
namespace's own Redshift-managed admin secret, not a Postgres login.

## Apply

```
terraform init
terraform plan
terraform apply
```

## Manual step: create the destination database and consumer views

No Terraform resource exists for `CREATE DATABASE ... FROM INTEGRATION` (confirmed absent from
the AWS provider's schema), so once `aws rds describe-integrations --integration-identifier
<integration_id output>` shows `Status: active`:

1. Run `sql/01_create_target_database.sql` against the workgroup's default database — creates the
   read-only destination database `poc3_zeroetl_target` from the integration.
2. Run `sql/02_consumer_views.sql` against the consumer database (`terraform output` doesn't
   expose this directly — it's `var.consumer_db_name`, default `poc3_consumer`, the namespace's
   own `db_name`) — creates a representative view over the destination database via Redshift
   cross-database query notation, using the same `change_request_header` table POC1's
   `mv_refresh.tf` and POC2's `iceberg_table_configs` already use, so all three POCs compare
   against identical data end to end.
3. Run `sql/03_powerbi_reader_role.sql` (also against `poc3_consumer`) — creates the DB
   username/password login Power BI's Redshift connection authenticates as, scoped to
   `bi.change_request_header_v` only.

## Validate

```
aws rds describe-integrations --integration-identifier $(terraform output -raw integration_id)
```

Then, connected to `poc3_zeroetl_target` (or via the Redshift Data API):

```sql
SELECT schema_name, table_name, table_state, reason
FROM svv_integration_table_state
WHERE target_database = 'poc3_zeroetl_target';
```

Every in-scope table should show `table_state = 'Synced'`; any table that doesn't must be
identified with its cause documented (SOW Functional Threshold). Then:

```
aws lambda invoke --function-name $(terraform output -raw poller_lambda_name) /dev/stdout
aws cloudwatch get-metric-data \
  --metric-data-queries '[{"Id":"m1","MetricStat":{"Metric":{"Namespace":"Custom/ZeroETL","MetricName":"UnsyncedTableCount"},"Period":300,"Stat":"Maximum"}}]' \
  --start-time $(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S) --end-time $(date -u +%Y-%m-%dT%H:%M:%S)
```

confirms the poller path end to end before waiting on the schedule.

The `validation/` folder has reusable queries for these checks (source PK/data-type audits,
sync-state summary, Failed-table reasons, physical-storage cross-check, consumer-view row count)
and `measure_latency.ps1`, a self-contained script that inserts a timestamped row on the source
and polls Redshift until it's visible, reporting the measured latency.

**Results from the validation performed on this integration** (schema `167597`, 198 tables):
- Replication latency: 3 runs, ~19-21s typical, one outlier of ~352s after ~2 days of no write
  activity (see below)
- Schema-change behaviour: `ADD COLUMN`, `RENAME COLUMN`, and `DROP COLUMN` all propagated
  automatically with no resync disruption and no manual intervention needed
- An unsupported-length value (>64KB) correctly triggered `Failed` state with a specific,
  actionable reason, and a real `Warning`-severity EventBridge event (confirming the pattern in
  `eventbridge.tf`)
- 196/198 tables Synced on initial validation, later reaching 198/198 after a capacity increase —
  see `CAPACITY_FINDINGS.md`

## Known follow-ups

- Confirm `postgreslt`'s engine version (16.13) against AWS's current zero-ETL supported-versions
  table before relying on eligibility — this was the SOW's Source Assessment task and hasn't been
  re-verified here (it clearly qualifies in practice, since the integration is live and
  replicating, but the formal check hasn't been re-run against AWS's published list).
- Power BI wiring is now built: `sql/03_powerbi_reader_role.sql` (DB user/password), and the
  shared gateway module (`terraform/powerbi-gateway`, its `poc3_redshift_security_group_id`
  variable) — apply that module's manual steps to finish connecting a report. Report content,
  refresh cadence, and RLS/security are still open per `poc_powerbi_questions.md` (repo root).
- Major-version-upgrade runbook (SOW requirement: an active integration blocks a source major-
  version upgrade; recreating the integration triggers a full backfill, not an incremental
  resume) — not yet written.
- Architecture-as-built diagram (deliverable D7) — not yet created.
