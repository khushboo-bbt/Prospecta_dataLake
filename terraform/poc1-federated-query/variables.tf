variable "aws_region" {
  description = "AWS region for the POC sandbox. Must match the source RDS instance's region — ap-southeast-1 (Singapore), confirmed against the actual instance, not ap-southeast-2 as originally assumed in the SOW."
  type        = string
  default     = "ap-southeast-1"
}

variable "name_prefix" {
  description = "Prefix applied to all resource names/tags created by this module."
  type        = string
  default     = "datalake-poc1"
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default = {
    Project = "DataLake"
    POC     = "POC1-Federated-Query"
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
  description = "Private subnet IDs (>= 2 AZs) used for the replica, PgBouncer tasks, the internal NLB and Redshift Serverless (datalake-poc-foundation output: private_subnet_ids)."
  type        = list(string)
}

variable "vpc_cidr" {
  description = "CIDR block of the sandbox VPC, used to scope the ECR interface endpoint security group (datalake-poc-foundation output: vpc_cidr)."
  type        = string
}

variable "bastion_security_group_id" {
  description = "Security group ID of the foundation module's temporary bastion (datalake-poc-foundation output: bastion_security_group_id). Allows one-off admin access (e.g. creating DB roles) to the analytics replica via SSM port forwarding through the bastion."
  type        = string
}

variable "route_table_ids" {
  description = "Route table IDs associated with the private subnets. Unused unless a future gateway endpoint is added here; kept for parity with poc2-dms-landing's foundation-wiring variables."
  type        = list(string)
  default     = []
}

variable "create_ecr_vpc_endpoints" {
  description = "Whether to create the ecr.api / ecr.dkr interface VPC endpoints needed for ECS Fargate to pull the PgBouncer image with no NAT/internet gateway in the sandbox VPC. Set to false if a later shared module already provisions these in the foundation VPC."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Source RDS for PostgreSQL (existing instance — managed outside this module)
# ---------------------------------------------------------------------------

variable "source_db_instance_identifier" {
  description = "DB instance identifier of the existing source Amazon RDS for PostgreSQL instance (postgreslt). Looked up via a data source to read its ARN/engine version for the read replica — this module never modifies the source instance."
  type        = string
  default     = "postgreslt"
}

variable "source_db_name" {
  description = "Database name (the client-confirmed in-scope one of ~28 on postgreslt) used only for the replica's connection string (Secrets Manager dbname, PgBouncer DB_NAME) — NOT a replication filter. A native RDS read replica replicates the entire source instance (every database on it); there is no way to scope replication to a single database the way DMS's table_mappings can scope to a single schema."
  type        = string
}

# ---------------------------------------------------------------------------
# Dedicated analytics read replica
# ---------------------------------------------------------------------------

variable "replica_instance_class" {
  description = "Instance class for the dedicated analytics read replica."
  type        = string
  default     = "db.m5.2xlarge"
}

variable "replica_storage_type" {
  description = "Storage type for the analytics read replica."
  type        = string
  default     = "gp3"
}

variable "statement_timeout_ms" {
  description = "statement_timeout (milliseconds) applied to the analytics replica via its parameter group, to abort runaway federated queries at the Postgres side."
  type        = number
  default     = 300000
}

variable "idle_in_transaction_session_timeout_ms" {
  description = "idle_in_transaction_session_timeout (milliseconds) applied to the analytics replica via its parameter group."
  type        = number
  default     = 60000
}

# ---------------------------------------------------------------------------
# Two per-use-case read-only DB logins, each with its own secret + Redshift
# external schema (materialized-view refresh, ad-hoc analysis).
# ---------------------------------------------------------------------------

variable "mv_refresh_db_username" {
  description = "Read-only Postgres login used by the Redshift external schema backing the scheduled materialized-view refresh."
  type        = string
  default     = "redshift_mv_refresh"
}

variable "mv_refresh_db_password" {
  description = "Password for mv_refresh_db_username. Passed in via TF_VAR or an uncommitted *.auto.tfvars file — never hard-coded."
  type        = string
  sensitive   = true
}

variable "adhoc_db_username" {
  description = "Read-only Postgres login used by the Redshift external schema backing ad-hoc analysis."
  type        = string
  default     = "redshift_adhoc"
}

variable "adhoc_db_password" {
  description = "Password for adhoc_db_username. Passed in via TF_VAR or an uncommitted *.auto.tfvars file — never hard-coded."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# PgBouncer on ECS Fargate, behind an internal NLB
# ---------------------------------------------------------------------------

variable "pgbouncer_image_tag" {
  description = "Tag of the PgBouncer image in the ECR repository this module creates. The image itself must be built and pushed out of band — see docker/pgbouncer/README.md — before the ECS service can start."
  type        = string
  default     = "latest"
}

variable "pgbouncer_task_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU). SOW specifies 0.5 vCPU per task."
  type        = string
  default     = "512"
}

variable "pgbouncer_task_memory" {
  description = "Fargate task memory (MB). SOW specifies 1 GB per task."
  type        = string
  default     = "1024"
}

variable "pgbouncer_desired_count" {
  description = "Number of PgBouncer Fargate tasks. SOW specifies two tasks."
  type        = number
  default     = 2
}

variable "pgbouncer_pool_size" {
  description = "PgBouncer default_pool_size (backend connections to the replica per pooled database)."
  type        = number
  default     = 20
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the PgBouncer task logs."
  type        = number
  default     = 30
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
  description = "max_query_execution_time workgroup config parameter, in seconds — Redshift Serverless's execution-time cap, the closest native equivalent to the SOW's WLM query monitoring rule (Serverless does not expose classic WLM). Matches statement_timeout_ms (300000ms = 300s) by default so both sides abort at the same point."
  type        = number
  default     = 300
}
