Subject: Inputs needed — Power BI reporting layer (POC 1-3)

Hi team,

To wire up Power BI reporting across the three POCs, we need the following from you:

1. **Power BI license** — Pro or Premium/PPU? (affects refresh frequency limits)
2. **Gateway hosting** — where should the on-premises data gateway run? Options:
   a. A VM on your network, with VPN/Direct Connect (or temporary allow-listed access) into the AWS sandbox VPC, or
   b. A Windows EC2 instance inside the sandbox VPC itself (we'd provision this — please confirm you're OK with the added scope)
3. **Gateway admin access** — who can install software (gateway service + ODBC drivers) on that machine?
4. **Redshift auth** — IAM-based or DB username/password for the Power BI connection?
5. **Athena auth** — an IAM user/role we can use for Athena + S3 (landing bucket) access, and an S3 staging bucket for query results
6. **Report content** — which tables/KPIs should the representative report per POC actually show?
7. **Refresh cadence** — how often should each report refresh?
8. **Access/security** — any row-level security requirement, or is a flat read-only report fine for POC purposes?
9. **Branding** — any existing Power BI theme/template to use?

Thanks,
