# DataLake POC — shared network foundation

A dedicated, isolated VPC in `ap-southeast-1` (Singapore) shared across all 3 POCs in this
engagement, connected to the existing source RDS instance's VPC via VPC peering.

## What this creates

- A new VPC (`10.50.0.0/16` by default) with 3 private subnets, one per AZ, no public
  subnets, no internet/NAT gateway.
- A single shared route table for the private subnets.
- An S3 gateway VPC endpoint (free) and interface VPC endpoints for Secrets Manager,
  CloudWatch Logs, and KMS — this keeps the VPC fully private while still letting DMS (or
  any future POC workload placed here) reach the AWS services it needs, with no internet
  egress path at all.
- A VPC peering connection to the existing RDS VPC (`vpc-primary-fuse-intenal`,
  `vpc-02881848f756c2e76`), same account/same region so `auto_accept = true` completes it
  without a manual accept step.

## What this touches on the existing (RDS) side — additive only

Two standalone resources are added to reach the source RDS instance. Neither adopts nor
manages the rest of the existing route table or security group — only these two entries
are added, nothing existing is changed or removed:

- One route in the RDS's own route table (`rtb-044115b113e436552`, serves all 3 of its
  subnets) pointing this VPC's CIDR at the new peering connection — alongside its existing
  NAT gateway route, S3 gateway endpoint, and the pre-existing `eks-fuse-internal` peering
  route.
- One ingress rule on the RDS's security group (`sg-069103bcb5acbd88d`) allowing Postgres
  (5432) from this VPC's CIDR — alongside its existing `10.70.1.0/24` and `10.40.0.0/16`
  ("sydney-vpc") rules.

The RDS instance itself is never referenced or modified by this module.

## Apply

```
cp terraform.tfvars.example terraform.tfvars   # only if you need to override a default
terraform init
terraform plan
terraform apply
```

All variables have defaults matching what was confirmed against the actual account, so
`terraform.tfvars` isn't strictly required unless you want to change the CIDR or AZs.

## Outputs to feed into each POC module

```
terraform output vpc_id
terraform output private_subnet_ids
terraform output private_route_table_id
```

For `poc2-dms-landing`, set:
- `vpc_id` = this module's `vpc_id` output
- `private_subnet_ids` = this module's `private_subnet_ids` output
- `route_table_ids` = `[this module's private_route_table_id output]`
- `create_s3_gateway_endpoint = false` (this module already creates one in the shared VPC)

## Known gaps / follow-ups

- Confirm the actual database name on `postgreslt` — the RDS API doesn't expose it
  (`DBName` comes back empty), likely because multiple databases exist on the instance.
- This module discovered and hardcodes the RDS-side IDs (`rds_vpc_id`,
  `rds_route_table_id`, `rds_security_group_id`) as variable defaults based on a point-in-
  time lookup — re-verify these if the RDS instance is ever recreated or its networking
  changes.
