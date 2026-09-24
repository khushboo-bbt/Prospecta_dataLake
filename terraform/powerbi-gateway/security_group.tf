# No ingress at all - admin access to the gateway is via SSM Session
# Manager port forwarding (see iam.tf + README.md), the same no-inbound,
# no-public-IP pattern as the foundation module's bastion. Only outbound
# rules are needed: HTTPS to the Power BI cloud service / Windows Update,
# plus a per-POC rule to whichever Redshift/database security group this
# gateway is wired up to (added below, additively, in the per-POC blocks).
resource "aws_security_group" "gateway" {
  name        = "${var.name_prefix}-gateway"
  description = "Power BI on-premises data gateway. No inbound - admin access is via SSM Session Manager port forwarding, not direct RDP."
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS to the Power BI cloud service, Azure relay, Microsoft sign-in, and Windows Update"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Athena streams query results to JDBC/ODBC drivers over 444, separate
  # from the regular Athena/Glue/S3 API traffic on 443 - confirmed via AWS's
  # own troubleshooting doc after the Athena ODBC connection consistently
  # hung with S3ClientError/"Request Timeout Has Expired" despite 443 to
  # every relevant endpoint (Athena, Glue, S3, STS) already testing fine.
  # Leaving this closed doesn't block the connection outright, just this one
  # specific call - which is exactly the confusing failure mode this was.
  egress {
    description = "Athena JDBC/ODBC result streaming (distinct from the 443 API traffic above)"
    from_port   = 444
    to_port     = 444
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-gateway" })
}

# ---------------------------------------------------------------------------
# POC1: additive rules on both sides, same pattern as
# datalake-poc-foundation/peering.tf's additive rule onto the source RDS
# security group - this module does not adopt or manage the rest of
# poc1-federated-query's Redshift security group.
# ---------------------------------------------------------------------------

resource "aws_security_group_rule" "gateway_to_poc1_redshift" {
  count = var.poc1_redshift_security_group_id != null ? 1 : 0

  type                     = "egress"
  security_group_id        = aws_security_group.gateway.id
  from_port                = 5439
  to_port                  = 5439
  protocol                 = "tcp"
  source_security_group_id = var.poc1_redshift_security_group_id
  description              = "Redshift Serverless (POC1)"
}

resource "aws_security_group_rule" "poc1_redshift_from_gateway" {
  count = var.poc1_redshift_security_group_id != null ? 1 : 0

  type                     = "ingress"
  security_group_id        = var.poc1_redshift_security_group_id
  from_port                = 5439
  to_port                  = 5439
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.gateway.id
  description              = "Power BI gateway"
}

# ---------------------------------------------------------------------------
# POC3: egress only, on this side. POC3's own security group already allows
# inbound 5439 from the whole sandbox VPC CIDR (poc3-zeroetl/networking.tf
# was built anticipating exactly this gateway), so no matching ingress rule
# is added there - adding one would be redundant, not additive.
# ---------------------------------------------------------------------------

resource "aws_security_group_rule" "gateway_to_poc3_redshift" {
  count = var.poc3_redshift_security_group_id != null ? 1 : 0

  type                     = "egress"
  security_group_id        = aws_security_group.gateway.id
  from_port                = 5439
  to_port                  = 5439
  protocol                 = "tcp"
  source_security_group_id = var.poc3_redshift_security_group_id
  description              = "Redshift Serverless (POC3)"
}
