variable "aws_region" {
  description = "AWS region for the POC sandbox. Must match the source RDS instance's region — ap-southeast-1 (Singapore), confirmed against the actual instance, not ap-southeast-2 as originally assumed in the SOW."
  type        = string
  default     = "ap-southeast-1"
}

variable "name_prefix" {
  description = "Prefix applied to all resource names/tags created by this module."
  type        = string
  default     = "datalake-poc3"
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default = {
    Project = "DataLake"
    POC     = "POC3-Zero-ETL"
  }
}

# ---------------------------------------------------------------------------
# Existing sandbox foundation (created outside this module) — fill in once the
# foundation phase (terraform/datalake-poc-foundation) has been applied.
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID of the existing POC sandbox VPC (datalake-poc-foundation output: vpc_id)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (>= 2 AZs) used for the Redshift Serverless workgroup (datalake-poc-foundation output: private_subnet_ids)."
  type        = list(string)
}

variable "vpc_cidr" {
  description = "CIDR block of the sandbox VPC. The Redshift Serverless workgroup's security group allows inbound 5439 from this CIDR only — the Power BI on-premises data gateway node lives inside this VPC (datalake-poc-foundation output: vpc_cidr)."
  type        = string
}

# ---------------------------------------------------------------------------
# Source RDS for PostgreSQL (existing instance — managed outside this module)
# ---------------------------------------------------------------------------

variable "source_db_instance_identifier" {
  description = "DB instance identifier of the existing source Amazon RDS for PostgreSQL instance (postgreslt). Used only to construct its ARN for the integration's source_arn and the Redshift resource policy's authorized source — this module never modifies the source instance's data."
  type        = string
  default     = "postgreslt"
}

variable "source_db_name" {
  description = "The named database on the source RDS instance that the integration replicates from (the DATABASE clause of CREATE DATABASE ... FROM INTEGRATION, and the first path segment of data_filter). Client-confirmed in-scope database — same mdo-core-crud agreed for poc1-federated-query and poc2-dms-landing."
  type        = string
  default     = "mdo-core-crud"
}

# ---------------------------------------------------------------------------
# Zero-ETL integration
# ---------------------------------------------------------------------------

variable "data_filter" {
  description = "Maxwell-syntax data filter scoping replication to the agreed in-scope subset (AWS RDS User Guide, 'Data filtering for Amazon RDS zero-ETL integrations'). For RDS for PostgreSQL a filter is mandatory once any is set, in <database>.<schema>.<table> form. Defaults to the same schema 167597 (198 tables) agreed for poc2-dms-landing, per the SOW's requirement that all three POCs compare against identical data."
  type        = string
  default     = "include: mdo-core-crud.167597.*"
}

variable "destination_db_name" {
  description = "Name of the read-only destination database Terraform's sql/01_create_target_database.sql script creates FROM INTEGRATION. Must differ from the namespace's own db_name (the consumer database) — Redshift creates this database, not this module, since no Terraform resource for CREATE DATABASE ... FROM INTEGRATION exists."
  type        = string
  default     = "poc3_zeroetl_target"
}

variable "consumer_db_name" {
  description = "Name of the namespace's own database (created at namespace creation) where consumer-facing views/materialized views are built, since the destination database above is read-only per the SOW."
  type        = string
  default     = "poc3_consumer"
}

# ---------------------------------------------------------------------------
# Redshift Serverless
# ---------------------------------------------------------------------------

variable "redshift_base_capacity" {
  description = "Base capacity (RPU) for the Redshift Serverless workgroup."
  type        = number
  default     = 8
}

variable "redshift_max_query_execution_time_seconds" {
  description = "max_query_execution_time workgroup config parameter, in seconds."
  type        = number
  default     = 300
}

# ---------------------------------------------------------------------------
# Sync-failure detection: scheduled Lambda poller (SOW: second of two
# independent detection paths, since RDS publishes no integration metrics to
# CloudWatch and tables can fail to synchronise without raising an error).
# ---------------------------------------------------------------------------

variable "poller_schedule" {
  description = "EventBridge schedule expression for invoking the SVV_INTEGRATION_TABLE_STATE poller Lambda."
  type        = string
  default     = "rate(5 minutes)"
}

variable "poller_timeout_seconds" {
  description = "Lambda timeout for the poller function. Generous relative to expected Data API round-trip time for a single-table-count query against ~198 tables."
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the poller Lambda."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Alarms / notifications
# ---------------------------------------------------------------------------

variable "alarm_notification_email" {
  description = "Email address to subscribe to the zero-etl-health SNS topic. Leave null to create the topic without a subscription (add one later via console/CLI)."
  type        = string
  default     = null
}
