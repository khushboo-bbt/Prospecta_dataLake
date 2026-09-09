# POC 2 — Part 1: Source replication enablement + DMS Serverless landing

Scope (SOW "POC 2 — AWS DMS to Amazon S3" items 1-3 only):

1. Enable logical replication on the source RDS instance via a custom DB parameter group.
2. Configure AWS DMS Serverless source (PostgreSQL) and target (S3) endpoints, 2-8 DCU, Parquet with date partitioning, tuned batch interval / min file size.
3. Run a full load followed by continuous CDC and confirm both land in the S3 landing zone.

Out of scope for this part: Glue crawler/catalog, Iceberg merge job, EventBridge job scheduling, Lake Formation grants, CloudWatch alarms, Power BI/Athena — these are later POC2 parts.

This module assumes the AWS Sandbox Foundation (VPC, subnets, route tables, IAM baseline, KMS/CloudTrail baseline) and the source RDS instance already exist. It does not create or modify the RDS instance itself.

## Prerequisites

- Terraform >= 1.5, AWS provider ~> 5.0.
- An existing sandbox VPC with at least two private subnets and their route tables.
- An existing source Amazon RDS for PostgreSQL instance, with its engine version, endpoint, DB name and (existing or to-be-created) replication user known.
- AWS CLI access to the sandbox account with permission to manage DMS, S3, IAM, KMS, Secrets Manager, CloudWatch Logs.

## Configure

```
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with real vpc/subnet/route-table/RDS values
export TF_VAR_source_db_password='...'   # never put this in a committed file
```

Narrow `table_mappings` in `terraform.tfvars` to the schema/table subset agreed with the Customer (SOW: "Agree the in-scope schema and table subset"). The default selects every table for initial connectivity testing only.

## Apply

```
terraform init
terraform plan
terraform apply
```

This creates: KMS CMK, Secrets Manager secret (DB credentials), S3 landing bucket, DMS IAM roles (+ account-wide `dms-vpc-role` / `dms-cloudwatch-logs-role` unless `create_dms_iam_service_roles = false`), a DMS security group + subnet group, an optional S3 gateway VPC endpoint, the DMS source/target endpoints, and the DMS Serverless replication config (created in a stopped state by default — `start_replication = false`).

## Manual step: associate the parameter group and reboot the source

Terraform creates the parameter group (`aws_db_parameter_group.logical_replication`, output as `parameter_group_name`) but deliberately does **not** attach it to the source RDS instance or reboot it — that instance is managed outside this module, and the SOW requires the reboot window to be agreed with the Customer beforehand. Once the window is agreed:

```
aws rds modify-db-instance \
  --db-instance-identifier <source_db_instance_identifier> \
  --db-parameter-group-name <parameter_group_name output> \
  --apply-immediately

aws rds reboot-db-instance \
  --db-instance-identifier <source_db_instance_identifier>
```

Confirm after reboot:

```
aws rds describe-db-parameters \
  --db-parameter-group-name <parameter_group_name output> \
  --query "Parameters[?ParameterName=='rds.logical_replication']"
```

`ParameterValue` must show `1` and `ApplyStatus` must show `in-sync`.

## Test the connection and start replication

```
aws dms test-connection --replication-config-arn <replication_config_arn output> --endpoint-arn <source_endpoint_arn output>
aws dms test-connection --replication-config-arn <replication_config_arn output> --endpoint-arn <target_endpoint_arn output>
```

Once both succeed, either set `start_replication = true` and re-apply, or start it directly:

```
aws dms start-replication --replication-config-arn <replication_config_arn output> --start-replication-type start-replication
```

## Validate the landing zone

```
aws s3 ls s3://<landing_bucket_name output>/ --recursive | head
```

Expect `LOAD*.parquet` files per source table from the full load, followed by date-partitioned CDC files as source writes occur. Cross-check replication progress and table state:

```
aws dms describe-table-statistics --replication-config-arn <replication_config_arn output>
```

Watch CloudWatch Logs at `<dms_cloudwatch_log_group output>` for load/apply errors.

## Known follow-ups (later POC2 parts)

- Glue crawler + Glue Data Catalog registration over this bucket.
- Glue PySpark CDC-merge job into Iceberg tables (dedupe by PK + commit timestamp, watermark guard).
- EventBridge-triggered job execution and scheduled Iceberg maintenance (compaction, snapshot expiry).
- CDC/replica-health CloudWatch alarms (`CDCLatencySource`, `CDCLatencyTarget`, `CDCChangesDiskSource`, `OldestReplicationSlotLag`, `TransactionLogsDiskUsage`, `FreeStorageSpace`) wired to SNS.
- S3 prefix + Lake Formation access segregation.
- Athena / Redshift Spectrum read validation and the Power BI report.
