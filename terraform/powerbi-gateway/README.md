# Shared Power BI on-premises data gateway

Client-confirmed answers so far (see `../../poc_powerbi_questions.md`): a Windows EC2 gateway
provisioned inside the sandbox VPC (not a VM on the client's own network), Redshift auth via a
DB username/password, and the first report is a flat read-only one over POC1's existing 9
materialized views (`bi.*` in `poc1-federated-query/sql/03_materialized_views.sql`).

One gateway, shared across POCs as each is wired up — not duplicated per POC (see the note in
`poc1-federated-query/README.md`). POC1 is wired up first; POC2 (Athena) and POC3 (a second
Redshift Serverless workgroup) can point at this same gateway later by populating this module's
other `*_security_group_id` variables once their own connectivity questions are answered.

## What this creates

- Its own **Internet Gateway + NAT Gateway + two new subnets** (one public, one private) inside
  the existing sandbox VPC — kept separate from `datalake-poc-foundation`'s shared private route
  table so the internet egress the gateway genuinely needs (to reach the Power BI cloud service)
  doesn't become a side-effect internet path for any other POC resource.
- A **Windows Server 2022 EC2 instance** (`t3.xlarge` by default) in the new private subnet, no
  public IP, no inbound security-group rules at all — admin access is via SSM Session Manager
  port forwarding, the same pattern as the foundation module's bastion.
- A dedicated **EC2 key pair** (public half only — you provide it) used solely to decrypt the
  instance's initial Windows Administrator password.
- A security group with outbound-only rules (443 to the Power BI cloud service / Windows Update),
  plus an additive ingress/egress pair wired into POC1's Redshift security group.

## Configure

```
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — vpc_id / vpc_cidr come from `terraform output` in
# datalake-poc-foundation; poc1_redshift_security_group_id from
# poc1-federated-query (see its outputs.tf)

ssh-keygen -t rsa -b 4096 -f powerbi-gateway-key -N ""
export TF_VAR_gateway_key_pair_public_key="$(cat powerbi-gateway-key.pub)"
```

## Apply

```
terraform init
terraform plan    # under a read-only AWS profile first — confirm the resource count
terraform apply   # under an elevated profile
```

This adds a NAT Gateway (hourly + per-GB charges) and a `t3.xlarge` Windows instance — recurring
cost, unlike most of the read-only/serverless resources elsewhere in this repo. Worth confirming
with whoever owns the sandbox budget before applying.

## Manual steps this module can't do

1. **Retrieve the initial Windows Administrator password:**
   ```
   aws ec2 get-password-data --instance-id $(terraform output -raw gateway_instance_id) \
     --priv-launch-key powerbi-gateway-key
   ```
2. **RDP in via SSM port forwarding** (no public IP, no open inbound port):
   ```
   aws ssm start-session --target $(terraform output -raw gateway_instance_id) \
     --document-name AWS-StartPortForwardingSession \
     --parameters '{"portNumber":["3389"],"localPortNumber":["13389"]}'
   ```
   Then point an RDP client at `localhost:13389` with the decrypted Administrator credentials.
3. **Verify outbound internet** from inside the instance (browse to `https://www.powerbi.com`) —
   confirms the NAT Gateway path before troubleshooting the gateway installer itself.
4. **Install the Power BI on-premises data gateway** (download from Microsoft), sign in with the
   Power BI account for this tenant, and register it with a recovery key — store that key
   somewhere durable (e.g. a Secrets Manager secret created by hand), it's needed to recover or
   migrate the gateway later and is not something this module manages.
5. **Install the Amazon Redshift ODBC driver** on the instance (needed for Power BI's Redshift
   connector when accessed through an on-premises gateway, as opposed to Power BI Desktop's
   direct connector which needs no gateway at all for a publicly reachable endpoint — this one
   isn't public, so the gateway path is required).
6. **Create the Redshift DB user** — `poc1-federated-query/sql/04_powerbi_reader_role.sql`, run
   against the POC1 workgroup as the namespace admin. This is the DB username/password Power BI's
   data source connection uses.
7. **Add the data source in Power BI Service**, under this gateway: Amazon Redshift, server =
   `terraform output redshift_workgroup_endpoint` (from poc1-federated-query, host only — no
   port), port `5439`, database `poc1_federated_query`, auth = Basic, using the
   `powerbi_reader` credentials from step 6.
8. **Build and publish the report** against the `bi` schema's 9 materialized views, then set its
   scheduled refresh. Power BI Pro caps scheduled refresh at 8/day; the MVs themselves refresh
   every 15 minutes (`poc1-federated-query`'s `mv_refresh_schedule`) — Pro can't match that
   cadence, so the report's refresh interval is a separate, coarser setting from the MV refresh
   itself. Revisit once the actual required cadence is confirmed (`poc_powerbi_questions.md`,
   question 7).

## Known follow-ups

- POC2 (Athena) and POC3 (Redshift) aren't wired into this gateway yet — their own
  `*_security_group_id`/auth questions in `../../poc_powerbi_questions.md` are still open.
- Only one gateway node — no HA. Microsoft supports a gateway cluster (multiple nodes behind one
  logical gateway) if this needs to survive a single-instance failure; not built here since it's
  POC scope.
- Recovery key storage (step 4 above) is a manual, out-of-band step — worth formalizing into a
  Secrets Manager secret if this gateway becomes more than a POC.
