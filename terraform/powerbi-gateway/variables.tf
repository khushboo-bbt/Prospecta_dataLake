variable "aws_region" {
  description = "AWS region for the shared Power BI gateway. Must match the sandbox VPC's region (ap-southeast-1)."
  type        = string
  default     = "ap-southeast-1"
}

variable "name_prefix" {
  description = "Prefix applied to all resource names/tags created by this module."
  type        = string
  default     = "datalake-powerbi-gateway"
}

variable "tags" {
  description = "Common tags applied to every resource. This gateway is shared across whichever POCs it's wired up to (POC1 first), not owned by any one of them."
  type        = map(string)
  default = {
    Project = "DataLake"
    Scope   = "Shared-PowerBI-Gateway"
  }
}

# ---------------------------------------------------------------------------
# Existing sandbox foundation (created outside this module)
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID of the existing POC sandbox VPC (datalake-poc-foundation output: vpc_id)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the sandbox VPC (datalake-poc-foundation output: vpc_cidr). Only used to size/validate the new subnets this module carves out of it."
  type        = string
}

variable "availability_zone" {
  description = "Single AZ to host the gateway EC2 instance and its NAT gateway. One gateway node is enough for POC scale - no HA requirement."
  type        = string
  default     = "ap-southeast-1a"
}

# ---------------------------------------------------------------------------
# Networking: this module's own public subnet (NAT gateway) + private
# subnet (the gateway instance itself), kept separate from the foundation
# module's shared private subnets/route table. The foundation VPC is
# otherwise fully private (see datalake-poc-foundation/vpc.tf) - the Power BI
# on-premises data gateway is the one workload that genuinely needs outbound
# internet (to reach the Power BI cloud service / Azure relay), and scoping
# that need to its own subnet+route table means no existing POC resource
# (replica, PgBouncer, Redshift ENIs) gains an internet egress path as a
# side effect of this module existing.
# ---------------------------------------------------------------------------

variable "public_subnet_cidr" {
  description = "CIDR for the new public subnet that hosts the NAT gateway's ENI + the IGW route. Must not overlap the foundation module's private subnets (10.50.0.0/20, 10.50.16.0/20, 10.50.32.0/20 by default)."
  type        = string
  default     = "10.50.48.0/24"
}

variable "gateway_subnet_cidr" {
  description = "CIDR for the new private subnet that hosts the Power BI gateway EC2 instance, routed to the internet via this module's own NAT gateway. Must not overlap the foundation subnets or public_subnet_cidr above."
  type        = string
  default     = "10.50.49.0/24"
}

# ---------------------------------------------------------------------------
# Gateway EC2 instance
# ---------------------------------------------------------------------------

variable "gateway_instance_type" {
  description = "EC2 instance type for the Power BI on-premises data gateway. Microsoft's stated minimum is 4 cores/8GB, recommended 8 cores/8GB for production; t3.xlarge (4 vCPU/16GB) is comfortable for POC-scale refresh volume against 9 materialized views."
  type        = string
  default     = "t3.xlarge"
}

variable "gateway_key_pair_public_key" {
  description = "Public key material (OpenSSH format, e.g. the contents of an id_rsa.pub) for the EC2 key pair used to decrypt the Windows Administrator password on first boot (`aws ec2 get-password-data`). Generate a dedicated key pair for this - never reuse one already in use elsewhere. Passed in via TF_VAR_gateway_key_pair_public_key or an uncommitted *.auto.tfvars file."
  type        = string
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size (GB) for the gateway instance. Windows Server 2022 + the Power BI gateway installer + the Redshift ODBC driver comfortably fit within the default."
  type        = number
  default     = 100
}

# ---------------------------------------------------------------------------
# Per-POC wiring: an ingress rule into each POC's own Redshift/database
# security group is added additively (this module never adopts or manages
# the rest of that security group's rules - same pattern as
# datalake-poc-foundation/peering.tf's additive rule onto the source RDS
# security group). Leave null to stand this module up before a given POC is
# ready to wire in.
# ---------------------------------------------------------------------------

variable "poc1_redshift_security_group_id" {
  description = "Security group ID of the POC1 Redshift Serverless workgroup (terraform output from poc1-federated-query: redshift_security_group_id). A 5439 ingress rule from this gateway's security group is added there."
  type        = string
  default     = null
}
