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
