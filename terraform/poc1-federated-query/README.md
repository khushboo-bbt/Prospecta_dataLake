# POC 1 — Amazon Redshift Federated Query

Scope (SOW "POC 1 — Amazon Redshift Federated Query (query in place)"): Redshift Serverless
queries the source Postgres live, with no data movement, but never touches the primary — all
traffic is funneled through a dedicated analytics read replica, pooled through PgBouncer, and
shielded behind materialized views that BI users are actually granted access to.

This module assumes the AWS Sandbox Foundation (`terraform/datalake-poc-foundation` — VPC,
subnets, route tables, VPC peering + security-group rule to the source RDS instance) already
exists. It does not create or modify the source RDS instance (`postgreslt`) itself, and — unlike
POC2 — it needs **no parameter-group change or reboot on the source at all**: a native RDS
read replica needs nothing beyond ordinary streaming replication, which the existing peering
connection and the RDS security-group's `5432` ingress rule (added by the foundation module)
already permit. This is why the SOW schedules POC1 (with POC3) as the fast path that doesn't
wait on POC2's reboot gate.

## What this creates

- A dedicated Amazon RDS for PostgreSQL **read replica** of the source instance
  (`db.m5.2xlarge` by default), in its own subnet group/security group inside the sandbox
  VPC, with a parameter group enforcing `statement_timeout` and
  `idle_in_transaction_session_timeout`. **This replicates the whole `postgreslt` instance —
  all ~28 databases on it, not only `var.source_db_name`.** Native RDS read replicas use
  instance-level physical replication with no per-database scoping (unlike POC2's DMS, whose
  logical replication can select down to a single schema via `table_mappings`). Storage size
  and encryption are both inherited from the source at creation — AWS rejects an explicit
  `allocated_storage`/`kms_key_id` for a same-region, same-account read replica — so neither
  is set in Terraform; resize storage afterward as a deliberate, separate change if needed.
- Two Secrets Manager secrets (one per read-only login: MV-refresh, ad-hoc), a customer-managed
  KMS key, and the IAM role Redshift's external schema authenticates with.
- **PgBouncer** on ECS Fargate (2 tasks, transaction pooling) behind an **internal NLB** — the
  only thing that ever opens a backend connection to the replica.
- A private **ECR repository** + `ecr.api`/`ecr.dkr` VPC interface endpoints for the PgBouncer
  image (see below — the sandbox VPC has no NAT/internet gateway).
- A **Redshift Serverless** namespace + workgroup (base 8 RPU), with a `max_query_execution_time`
  workgroup config parameter as the closest native equivalent to the SOW's WLM query monitoring
  rule (Serverless doesn't expose classic WLM).

## Known deviation from the SOW's architecture: no NAT gateway

The SOW's cost table (Table 12.2) assumes a shared NAT gateway. The foundation module that was
actually built (`terraform/datalake-poc-foundation`) is fully private instead — no NAT/internet
gateway at all, only an S3 gateway endpoint and a fixed set of interface endpoints. ECS Fargate
therefore can't pull a public Docker Hub image directly. Rather than add a NAT gateway (which
would also mean the replica/PgBouncer/Redshift ENIs gain an internet egress path they don't need),
this module stays consistent with the existing fully-private design: the PgBouncer image is
built from `docker/pgbouncer/` and pushed to a private ECR repo this module creates, reachable
over the new `ecr.api`/`ecr.dkr` interface endpoints with no internet path at all.

## Configure

```
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — vpc_id / private_subnet_ids / vpc_cidr come from
# `terraform output` in datalake-poc-foundation
export TF_VAR_mv_refresh_db_password='...'   # never put these in a committed file
export TF_VAR_adhoc_db_password='...'
```

## Apply

```
terraform init
terraform plan    # under a read-only AWS profile first — confirm the resource count
terraform apply   # under an elevated profile
```

## Manual steps this module can't do

1. **Build and push the PgBouncer image** — see `docker/pgbouncer/README.md`. The ECS service
   will not reach a steady state until an image exists at the ECR repo/tag
   `terraform output pgbouncer_ecr_repository_url` points at.
2. **Create the two read-only DB roles on the replica** — `sql/01_read_only_roles.sql`. Narrow
   the schema/table grants to the client-confirmed in-scope subset (same caveat as POC2's
   `table_mappings` — the schema name isn't hardcoded here because it isn't confirmed yet).
3. **Create the external schemas and point them at PgBouncer** —
   `sql/02_external_schema.sql`, using `terraform output pgbouncer_nlb_dns_name`,
   `redshift_federated_query_role_arn`, `mv_refresh_db_secret_arn`, `adhoc_db_secret_arn`.
4. **Build the materialized views and BI grants** — `sql/03_materialized_views.sql`. This is
   also where predicate-pushdown is validated (`EXPLAIN`) and where a join restriction that
   won't push down gets encapsulated in a Postgres view on the replica — both schema-specific,
   not scripted here.
5. **Covering indexes on the replica for the federated predicates** — depends on the actual
   query patterns/table subset; not created by this module.
6. **Concurrency load test** — measure connection count, replica CPU and replica lag against
   the concurrency ceiling under representative BI activity; an operational activity, not
   infrastructure.
7. **Power BI report** — connects to the Redshift workgroup via the native connector, through
   the shared on-premises data gateway node (SOW Table 12.2: one gateway shared across all
   three POCs) — see `terraform/powerbi-gateway`, plus `sql/04_powerbi_reader_role.sql` for the
   DB username/password login that connection authenticates as.

## Validate

```
terraform output pgbouncer_nlb_dns_name
terraform output redshift_workgroup_endpoint
```

Connect to the Redshift workgroup and confirm:

```sql
EXPLAIN SELECT * FROM ext_adhoc.<table_name> WHERE <predicate>;
```

shows the filter applied on the Postgres side of the plan, then confirm a join between a
federated table and a local Redshift table executes correctly, per the SOW's validation step.

## Known follow-ups

- Per-role (rather than instance-wide) Postgres timeouts, if the two logins ever need to
  diverge — `ALTER ROLE ... SET`, commented out in `sql/01_read_only_roles.sql`.
- If `terraform plan` shows a persistent diff on `aws_redshiftserverless_workgroup.poc1`'s
  `config_parameter` after the first apply, see the note in `redshift.tf` — a known AWS
  provider quirk with partial `config_parameter` lists.
- The shared Power BI on-premises data gateway node (EC2, itemised in SOW Table 12.2) now lives
  in `terraform/powerbi-gateway` — apply that module and its manual steps (README there) to
  finish wiring up POC1's report.
