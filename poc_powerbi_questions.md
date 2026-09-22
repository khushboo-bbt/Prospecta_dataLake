Subject: Inputs needed — Power BI reporting layer (POC 1-3)

Hi team,

To wire up Power BI reporting across the three POCs, we need the following from you:

1. ~~**Power BI license** — Pro or Premium/PPU?~~ **Answered:** licensed, POC1 proceeding.
2. ~~**Gateway hosting**~~ **Answered (POC1):** option (b) — a Windows EC2 instance inside the
   sandbox VPC, provisioned by us. Built in `terraform/powerbi-gateway`.
3. **Gateway admin access** — who can install software (gateway service + ODBC drivers) on that
   machine? Currently us, via SSM Session Manager port forwarding (no client-side access set up
   yet) — confirm if the client side also needs direct access to this instance.
4. ~~**Redshift auth**~~ **Answered (POC1):** DB username/password. See
   `terraform/poc1-federated-query/sql/04_powerbi_reader_role.sql`.
5. **Athena auth** (POC2) — an IAM user/role we can use for Athena + S3 (landing bucket) access,
   and an S3 staging bucket for query results. Still open.
6. ~~**Report content**~~ **Answered (POC1):** the 9 existing `bi.*` materialized views, flat —
   no new modeling for the first pass.
7. **Refresh cadence** — how often should each report refresh? Still open — note the MVs
   themselves already refresh every 15 minutes; the Power BI report's own scheduled refresh is a
   separate, coarser setting (Pro caps at 8/day) that still needs a client-confirmed value.
8. **Access/security** — any row-level security requirement, or is a flat read-only report fine
   for POC purposes? Still open — POC1 is currently built assuming flat/read-only
   (`bi_reader` role, no RLS).
9. **Branding** — any existing Power BI theme/template to use? Still open.

Thanks,
