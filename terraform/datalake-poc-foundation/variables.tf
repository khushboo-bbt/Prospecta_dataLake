variable "aws_region" {
  description = "Region for the DataLake POC VPC. Must match the source RDS instance's region (ap-southeast-1 / Singapore) so peering stays same-region."
  type        = string
  default     = "ap-southeast-1"
}

variable "name_prefix" {
  description = "Prefix applied to all resource names/tags created by this module."
  type        = string
  default     = "datalake-poc"
}

variable "tags" {
  description = "Common tags applied to every resource. Shared across all 3 POCs using this VPC."
  type        = map(string)
  default = {
    Project = "DataLake"
    Scope   = "Shared-POC-Foundation"
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the new DataLake POC VPC. Must not overlap with any existing VPC in the account (10.70.0.0/16, 10.90.0.0/16, 172.31.0.0/16, 85.95.0.0/16, 83.93.0.0/16, or the peered 11.22.0.0/16 / 10.40.0.0/16 ranges)."
  type        = string
  default     = "10.50.0.0/16"
}

variable "availability_zones" {
  description = "AZs for the private subnets. Matches the source RDS instance's subnet group (all 3 AZs in ap-southeast-1) so future POC resources have the same AZ options."
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets, one per entry in availability_zones."
  type        = list(string)
  default     = ["10.50.0.0/20", "10.50.16.0/20", "10.50.32.0/20"]
}

# ---------------------------------------------------------------------------
# Existing source RDS network (discovered via read-only lookup, not managed
# by this module) — used only to attach the peering connection and the two
# additive touches (one route, one security-group rule) needed to reach it.
# ---------------------------------------------------------------------------

variable "rds_vpc_id" {
  description = "VPC ID of the existing VPC that hosts the source RDS instance (vpc-primary-fuse-intenal)."
  type        = string
  default     = "vpc-02881848f756c2e76"
}

variable "rds_vpc_cidr" {
  description = "CIDR block of the existing RDS VPC, used for the peering route."
  type        = string
  default     = "10.70.0.0/16"
}

variable "rds_route_table_id" {
  description = "Route table ID that serves the RDS instance's subnets in its own VPC. A single new route to the DataLake POC VPC is added here (additive only — no existing routes are touched)."
  type        = string
  default     = "rtb-044115b113e436552"
}

variable "rds_security_group_id" {
  description = "Security group ID currently attached to the source RDS instance. A single new ingress rule for Postgres (5432) from the DataLake POC VPC CIDR is added here (additive only — no existing rules are touched)."
  type        = string
  default     = "sg-069103bcb5acbd88d"
}

variable "rds_port" {
  description = "Port the source RDS instance listens on."
  type        = number
  default     = 5432
}
