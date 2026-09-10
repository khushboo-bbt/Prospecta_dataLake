variable "aws_region" {
  description = "AWS region for the POC sandbox. Must match the source RDS instance's region — ap-southeast-1 (Singapore), confirmed against the actual instance, not ap-southeast-2 as originally assumed."
  type        = string
  default     = "ap-southeast-1"
}

variable "name_prefix" {
  description = "Prefix applied to all resource names/tags created by this module."
  type        = string
  default     = "datalake-poc2"
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default = {
    Project = "DataLake"
    POC     = "POC2-DMS-Glue-Iceberg"
    Phase   = "Part1-DMS-Landing"
  }
}

# ---------------------------------------------------------------------------
# Existing sandbox foundation (created outside this module) — fill in once the
# foundation phase (VPC, subnets, security baseline) has been provisioned.
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID of the existing POC sandbox VPC."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (>= 2 AZs) used for the DMS Serverless replication and any interface VPC endpoints."
  type        = list(string)
}

variable "route_table_ids" {
  description = "Route table IDs associated with the private subnets, used to attach the S3 gateway endpoint."
  type        = list(string)
}

variable "create_s3_gateway_endpoint" {
  description = "Whether to create the S3 gateway VPC endpoint. Set to false if the sandbox foundation already provisioned it — e.g. the terraform/datalake-poc-foundation module already creates one in the shared VPC, so set this to false when wiring this module to that VPC."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Source RDS for PostgreSQL (existing instance — managed outside this module)
# ---------------------------------------------------------------------------

variable "source_db_instance_identifier" {
  description = "DB instance identifier of the existing source Amazon RDS for PostgreSQL instance."
  type        = string
}

variable "source_db_engine_version" {
  description = "Engine version of the source RDS instance, used to pick the parameter group family (e.g. 15 -> postgres15)."
  type        = string
}

variable "source_db_endpoint" {
  description = "Reader/writer endpoint hostname of the source RDS instance."
  type        = string
}

variable "source_db_port" {
  description = "Port of the source RDS instance."
  type        = number
  default     = 5432
}

variable "source_db_name" {
  description = "Database name on the source RDS instance to replicate from."
  type        = string
}

variable "source_db_username" {
  description = "Username DMS will authenticate as. The password is stored separately in Secrets Manager (see source_db_password)."
  type        = string
  default     = "dms_replication_user"
}

variable "source_db_password" {
  description = "Password for the DMS replication user. Passed in via TF_VAR or a *.auto.tfvars file that is not committed — never hard-code this."
  type        = string
  sensitive   = true
}

variable "source_db_ssl_mode" {
  description = "SSL mode DMS uses to connect to the source (require | verify-ca | verify-full | none)."
  type        = string
  default     = "require"
}

variable "dms_security_group_ids" {
  description = "Additional security group IDs to attach to the DMS replication ENIs, e.g. one that already permits egress to the RDS instance. Leave empty to rely solely on the security group this module creates."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# DMS logical replication parameter group
# ---------------------------------------------------------------------------

variable "max_replication_slots" {
  description = "rds.postgres max_replication_slots parameter value."
  type        = string
  default     = "20"
}

variable "max_wal_senders" {
  description = "rds.postgres max_wal_senders parameter value."
  type        = string
  default     = "20"
}

variable "wal_sender_timeout" {
  description = "wal_sender_timeout in milliseconds. 0 disables the timeout (AWS DMS recommendation for CDC sources)."
  type        = string
  default     = "0"
}

# ---------------------------------------------------------------------------
# Pre-existing custom parameter values to preserve when the source instance
# already has its own custom parameter group. Terraform's parameter group is
# a brand-new object — anything not explicitly set here reverts to the
# engine family default the moment it's attached, silently, for every
# database on the instance. Set these to whatever the instance's *current*
# custom group already has (source_db_instance_identifier's existing group)
# so attaching ours changes only the replication-related settings above.
# Leave any of these as null if the instance has no existing custom value to
# preserve for that parameter.
# ---------------------------------------------------------------------------

variable "preserve_idle_in_transaction_session_timeout" {
  description = "Existing idle_in_transaction_session_timeout value (ms) on the source instance's current parameter group, to carry forward. Null to leave at the engine default."
  type        = string
  default     = null
}

variable "preserve_log_min_duration_statement" {
  description = "Existing log_min_duration_statement value (ms) on the source instance's current parameter group, to carry forward. Null to leave at the engine default."
  type        = string
  default     = null
}

variable "preserve_pg_stat_statements_track_planning" {
  description = "Existing pg_stat_statements.track_planning value on the source instance's current parameter group, to carry forward. Null to leave at the engine default."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# DMS Serverless capacity + landing zone tuning
# ---------------------------------------------------------------------------

variable "dms_min_capacity_units" {
  description = "Minimum DMS Serverless capacity units (DCU)."
  type        = number
  default     = 2
}

variable "dms_max_capacity_units" {
  description = "Maximum DMS Serverless capacity units (DCU)."
  type        = number
  default     = 8
}

variable "cdc_max_batch_interval_seconds" {
  description = "Maximum time in seconds DMS buffers CDC changes before writing a batch to S3. Larger values reduce small-file proliferation at the cost of freshness."
  type        = number
  default     = 60
}

variable "cdc_min_file_size_kb" {
  description = "Minimum file size in KB DMS targets before flushing a CDC batch to S3, to control small-file proliferation."
  type        = number
  default     = 32000
}

variable "date_partition_sequence" {
  description = "Date partition folder format DMS uses when writing to S3 (YYYYMMDD | YYYYMMDDHH | YYYYMM | MMYYYYDD | DDMMYYYY)."
  type        = string
  default     = "YYYYMMDD"
}

variable "landed_schema_prefix" {
  description = "The source schema name DMS lands under in S3 (s3://<bucket>/<this>/<table>/...) — must match the schema-name used in table_mappings below. Scopes the Glue crawler to just this prefix rather than the whole bucket."
  type        = string
  default     = "167597"
}

variable "iceberg_database_name" {
  description = "Glue Data Catalog database for the curated, deduplicated Iceberg tables — separate from glue_database_name (the raw landing-zone catalog)."
  type        = string
  default     = "datalake_poc2_curated"
}

variable "iceberg_table_configs" {
  description = "Table -> {pk: [...], append_only: bool} config for the Iceberg merge job. Only tables listed here get curated; add an entry to extend coverage. append_only=true skips dedup/merge entirely (e.g. Hibernate Envers *_aud-style audit tables where every revision must be kept)."
  type = map(object({
    pk          = list(string)
    append_only = optional(bool, false)
  }))
  default = {
    change_request_header    = { pk = ["crnumber", "moduleid"] }
    chng_1_487809            = { pk = ["uuid"] }
    crud_metadata_mdo        = { pk = ["fieldid", "moduleid", "structureid", "tenantid"] }
    crud_next_mdo_number     = { pk = ["moduleid", "tenantid", "setting_uuid"] }
    crud_table_mapping       = { pk = ["pk_uuid"] }
    databasechangelog        = { pk = ["id", "author", "filename"] }
    databasechangeloglock    = { pk = ["id"] }
    dyn_1_487809             = { pk = ["recordnumber", "tenantid"] }
    mdo_guardrail_properties = { pk = ["guardrail_name"] }
  }
}

variable "alarm_notification_email" {
  description = "Email address to subscribe to the replica-health SNS topic. Leave null to create the topic without a subscription (add one later via console/CLI)."
  type        = string
  default     = null
}

variable "cdc_latency_threshold_seconds" {
  description = "Alarm if CDCLatencySource/CDCLatencyTarget (DMS falling behind reading source WAL / writing to S3) exceeds this many seconds, sustained."
  type        = number
  default     = 300
}

variable "replication_slot_disk_usage_threshold_mb" {
  description = "Alarm if the source RDS instance's ReplicationSlotDiskUsage (WAL retained for the logical replication slot) exceeds this many MB — the exact 'stopped/stale slot accumulating WAL' scenario flagged earlier, since this instance hosts ~28 other databases."
  type        = number
  default     = 5000
}

variable "oldest_replication_slot_lag_threshold_mb" {
  description = "Alarm if OldestReplicationSlotLag (how far the slowest replication slot has fallen behind) exceeds this many MB."
  type        = number
  default     = 5000
}

variable "transaction_logs_disk_usage_threshold_mb" {
  description = "Alarm if TransactionLogsDiskUsage (total WAL disk usage on the source instance) exceeds this many MB."
  type        = number
  default     = 20000
}

variable "free_storage_space_threshold_bytes" {
  description = "Alarm if FreeStorageSpace on the source RDS instance drops below this many bytes."
  type        = number
  default     = 5368709120 # 5 GiB
}

variable "iceberg_merge_schedule" {
  description = "EventBridge schedule expression for the Iceberg merge job — how often new CDC changes get merged in."
  type        = string
  default     = "rate(15 minutes)"
}

variable "iceberg_maintenance_schedule" {
  description = "EventBridge schedule expression for the Iceberg maintenance job (compaction + snapshot expiry) — runs far less often than the merge job."
  type        = string
  default     = "cron(0 18 * * ? *)" # 18:00 UTC daily = 23:30 IST
}

variable "iceberg_snapshot_retention_hours" {
  description = "Iceberg snapshots older than this are eligible for expiry during maintenance (retain_last=1 always keeps at least the most recent one regardless)."
  type        = number
  default     = 168 # 7 days
}

variable "glue_database_name" {
  description = "Glue Data Catalog database name for the landed data. Underscores, not hyphens — Athena/Presto have trouble with unquoted hyphenated identifiers."
  type        = string
  default     = "datalake_poc2"
}

variable "table_mappings" {
  description = "DMS table-mapping selection rules (JSON-encodable object), agreed with the Customer per the source subset. Defaults to the full schema for initial testing — narrow this before the real POC run."
  type        = any
  default = {
    rules = [
      {
        rule-type = "selection"
        rule-id   = "1"
        rule-name = "1"
        object-locator = {
          schema-name = "%"
          table-name  = "%"
        }
        rule-action = "include"
      }
    ]
  }
}

variable "start_replication" {
  description = "Whether Terraform should start the DMS Serverless replication (full-load-and-cdc) immediately after creating it."
  type        = bool
  default     = false
}

variable "create_dms_iam_service_roles" {
  description = "Whether to create the account-wide DMS service IAM roles (dms-vpc-role, dms-cloudwatch-logs-role). These are singletons per account — set to false if another POC/module already created them."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for DMS replication logs."
  type        = number
  default     = 30
}

variable "create_full_load_only_replication" {
  description = "Whether to create a second, temporary DMS Serverless replication config using replication_type = \"full-load\" (no CDC). Use this to land real data in S3 while rds.logical_replication is still disabled on the source — CDC-bundled full-load-and-cdc requires it, plain full-load does not. Remove (set to false) once the main full-load-and-cdc replication can run instead."
  type        = bool
  default     = false
}
