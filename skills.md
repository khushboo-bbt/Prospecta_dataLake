# Terraform + AWS DMS on a shared account — working notes

Practical lessons from building `terraform/datalake-poc-foundation` and
`terraform/poc2-dms-landing` against a real, shared AWS account. Read this
before starting the next POC (rest of POC2, Federated Query, Zero-ETL) —
most of the pain below is not specific to DMS and will recur.

## 1. Discover before you assume anything

The SOW/README's assumptions were wrong on almost every environmental fact.
Verify every one of these against the live account before writing Terraform,
using read-only credentials:

- **Region.** The module defaulted to `ap-southeast-2` "per the SOW" — the
  actual source RDS instance was in `ap-southeast-1`. Check
  `aws rds describe-db-instances` yourself; don't trust a written spec.
- **VPC.** Don't guess which VPC is "the sandbox" from naming alone —
  `vpc-primary-fuse-sydney` sounds right and was not the one anything was
  peered to. List VPCs, check CIDR overlaps, and ask if it's ambiguous.
- **Database name.** `describe-db-instances` often returns an empty
  `DBName` — the instance can host dozens of separate databases (this one
  had ~28, one per microservice). Connect and run `\l` before assuming a
  database name. Don't guess `postgres` and move on.
- **Schema.** Even inside the right database, `public` may be empty or
  contain only framework/migration tables (Liquibase, ShedLock, etc.), not
  business data. Multi-tenant platforms often use numeric schema-per-tenant
  patterns — list schemas and table counts before picking scope.
- **Master username.** Don't assume `postgres` — RDS lets you set any
  master username at creation time (this one was `rds_master`).
- **Existing custom parameter groups / security group rules / peering
  connections.** Check what's already there and why, before creating
  something that might duplicate or conflict with it (e.g. we found an
  existing cross-account peering connection that explained a security-group
  CIDR nobody could otherwise account for).

## 2. AWS credentials: separate profiles by privilege, not by convenience

- Keep a **read-only** profile as the default for everything exploratory:
  `terraform plan`, `describe-*` calls, checking whether a resource already
  exists. `terraform plan` almost never needs write access — it only calls
  create/write APIs during `apply`.
- Switch to an **elevated** profile (SystemAdmin/Administrator) only for the
  moment of `terraform apply` or a specific mutating CLI call, then switch
  back.
- **Check what the elevated profile actually allows before assuming it's
  suf­ficient.** A custom SSO permission set can be an explicit allow-list
  missing entire services (we found SystemAdmin here had no `secretsmanager`,
  no `dms`, and only `kms:DescribeKey`/`ListAliases` — nowhere near enough to
  apply a DMS module). Pull the actual policy
  (`iam get-role-policy`/`list-attached-role-policies`) rather than assuming
  a role named "SystemAdministrator" has admin-shaped access.
- Never type real secrets (passwords, access keys) into a chat/agent
  session — enter them at interactive prompts in your own terminal, or set
  them as local environment variables (`$env:TF_VAR_...` in PowerShell,
  `export TF_VAR_...` in bash) that only you can see.
- Session tokens from a manually-copied SSO credential (not
  `aws configure sso`) expire and need re-copying from the SSO portal —
  `aws sso login` won't refresh them.

## 3. Module structure: separate the shared foundation from each POC

- Put the VPC/subnets/peering/endpoints that multiple POCs will share into
  their own root module (`datalake-poc-foundation` here), not into the first
  POC's module. Wire other POC modules to its outputs
  (`vpc_id`, `private_subnet_ids`, `route_table_ids`).
- When two VPCs need to talk to each other, prefer **VPC peering** over
  Transit Gateway for a small number of VPCs — no hourly charge, only
  data-transfer cost, versus TGW's per-attachment-hour + per-GB pricing.
- Adding a route to an *existing* VPC's route table or a rule to an existing
  security group should be a **standalone `aws_route` / `aws_security_group_rule`
  resource**, never a full `aws_route_table` / `aws_security_group` resource —
  the latter would adopt and fully manage (and could delete) everything else
  already on that resource.
- For one-off admin access to a private RDS instance (creating a DB user,
  running discovery SQL), stand up a **temporary SSM-only bastion**: no SSH,
  no public IP, no inbound security group rules — the SSM agent connects
  outbound-only via `ssm`/`ssmmessages`/`ec2messages` VPC interface endpoints.
  Tunnel through it with
  `aws ssm start-session --document-name AWS-StartPortForwardingSessionToRemoteHost`.
  For TLS verify-full through the tunnel, set `host=<real-hostname>
  hostaddr=127.0.0.1` in the `psql` connection string — keeps full
  certificate hostname verification instead of downgrading to `verify-ca`.

## 4. Safety workflow that actually caught real mistakes

- Always run `terraform plan` under the read-only profile first, read the
  full plan (resource-by-resource, not just the summary line), and get
  explicit confirmation before `apply`. This isn't ceremony — it caught a
  disallowed character in a security-group description before it became an
  `apply`-time failure.
- After any fix, re-run `fmt -check -diff` and `validate` before the next
  `plan`/`apply` cycle. Cheap, catches syntax slips immediately.
- Confirm the *exact* resource count in every plan (`N to add, N to change,
  N to destroy`) before typing `yes` — especially once you're editing a repo
  a client is watching. If a change should be purely additive, verify the
  plan shows zero `to change`/`to destroy`.
- A `terraform.tfvars` toggle variable (e.g.
  `create_full_load_only_replication`) is a clean way to stage an optional,
  removable piece of infrastructure without touching what already works —
  flip it back to `false` to cleanly tear down just that piece.

## 5. AWS DMS Serverless-specific gotchas (all discovered via real `apply`/`start-replication` attempts, not docs)

- `aws_dms_endpoint` cannot set `server_name`/`port` **and**
  `secrets_manager_access_role_arn`/`secrets_manager_arn` at the same time —
  conflicting arguments. Pick one auth mode; if using Secrets Manager, the
  secret's JSON must already carry `host`/`port`/`dbname`/`username`/`password`.
- A KMS CMK backing a CloudWatch Logs log group needs an explicit key-policy
  statement for `logs.<region>.amazonaws.com` (not just `logs.amazonaws.com`),
  including a `kms:EncryptionContext:aws:logs:arn` condition — otherwise
  `CreateLogGroup` fails with `AccessDeniedException`.
- An IAM role backing `secrets_manager_access_role_arn` on a DMS **source**
  endpoint must trust the **regional** DMS service principal
  (`dms.<region>.amazonaws.com`), not just `dms.amazonaws.com` — otherwise
  `CreateEndpoint` fails with `InvalidParameterValueException`. (A parallel
  role backing an S3 **target** endpoint worked fine with the generic
  principal — this only bit the Secrets-Manager-authenticated source.)
- DMS Serverless provisions its actual compute via the
  `AWSServiceRoleForDMSServerless` service-linked role, which shows up in
  CloudTrail as a real, nameable assumed role — **not** as an opaque
  `Service: dms.amazonaws.com` caller. A KMS key-policy statement scoped to
  `Principal: {Service: "dms.amazonaws.com"}` does **not** cover it. Granting
  the exact role ARN directly in the key policy still hit
  `KMSKeyNotAccessibleFault` in practice (root cause not fully resolved) — the
  pragmatic fix was to **not** pass a custom `kms_key_id` into
  `compute_config` at all and let DMS use its own default-managed key
  (`alias/aws/dms`) for the replication instance's internal storage. Keep the
  custom CMK for the S3 bucket / Secrets Manager secret / CloudWatch Logs —
  those all worked fine with explicit key-policy grants.
- `compute_config.kms_key_id` (and likely similar "optional but computed"
  attributes elsewhere) does not revert to unset just by removing it from
  config — Terraform keeps whatever's already recorded in state. Force it
  with `terraform apply -replace="<resource.address>"`.
- `replication_type = "full-load"` does not support
  `date_partition_enabled = true` on the S3 target endpoint (date
  partitioning only applies to CDC output) — `CreateReplicationConfig` fails
  with `InvalidParameterValueException`. A full-load-only variant needs its
  own target endpoint with `date_partition_enabled = false`.
- On RDS for PostgreSQL, even the master user isn't a true superuser — you
  can't `CREATE ROLE ... WITH REPLICATION` directly. Grant the `rds_replication`
  pseudo-role instead: `GRANT rds_replication TO <role>`.
- Postgres roles are cluster-wide but grants are per-database — creating
  `dms_replication_user` once makes it visible everywhere, but you must
  `GRANT SELECT`/`GRANT USAGE ON SCHEMA` separately inside every database (and
  every schema) DMS actually needs to read from.
- `full-load-and-cdc` replication needs the CDC replication slot established
  **before** any row is copied (it's the consistency anchor between the
  snapshot and the CDC stream) — if `rds.logical_replication` is off, the
  whole task fails immediately with `TablesLoaded: 0`, before copying
  anything. A plain `full-load` config sidesteps this entirely if you need
  real data in the target sooner.
- DMS Serverless has **no standalone connection-test API** for endpoints —
  the console says so outright ("Serverless automatically validates your
  endpoint connection as part of the startup sequence when you start
  replication"). The classic `aws dms test-connection` CLI needs a
  replication-*instance* ARN that doesn't exist for Serverless. Starting
  replication *is* the test.
- When a `describe-replications` failure message is generic
  ("Failed to provision underlying resources..."), go straight to
  CloudTrail (`lookup-events`, filtered by a tight time window around the
  failure) rather than guessing — the real error (e.g. the exact
  `KMSKeyNotAccessibleFault` message and which role hit it) is usually only
  visible there, not in the DMS API response.

## 6. Windows / PowerShell / Git Bash friction

- PowerShell doesn't support `&&`/`||` — use `;` to chain unconditionally,
  or `if ($?) { ... }` for conditional chaining. Bash tool sessions and the
  user's own PowerShell terminal are different shells; give the right
  syntax for whichever one a command is meant to run in.
- Environment variables set in one PowerShell window (`$env:VAR = ...`)
  do not carry over to a different window/session — re-set them per window.
- Git Bash (MSYS2) auto-converts arguments that look like POSIX absolute
  paths (e.g. `/dms/...`, `/foo`) into mangled Windows paths, breaking any
  AWS CLI parameter that happens to start with `/`. Prefix the command with
  `MSYS_NO_PATHCONV=1` when this happens (symptom: a regex-validation error
  on a parameter that obviously matches the stated pattern).
- Installing tools via `winget` (Terraform, Session Manager Plugin, etc.)
  adds them to the **system PATH**, but already-open terminal
  sessions/tool calls won't see the update — open a fresh window, or locate
  the installed `.exe` directly under
  `AppData\Local\Microsoft\WinGet\Packages\...` in the meantime.
