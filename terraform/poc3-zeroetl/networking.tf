# Unlike poc1's federated-query workgroup (egress-only — it only ever
# initiates federated queries outbound), this workgroup is itself a query
# target: the consumer database is queried directly by the Power BI native
# Redshift connector, via the shared on-premises data gateway node that lives
# inside this same sandbox VPC. So inbound 5439 from the VPC CIDR is required.
resource "aws_security_group" "redshift" {
  name        = "${var.name_prefix}-redshift"
  description = "Redshift Serverless workgroup for POC3. Inbound 5439 from the sandbox VPC (Power BI gateway), egress to AWS service VPC endpoints."
  vpc_id      = var.vpc_id

  ingress {
    description = "Power BI gateway node and other in-VPC clients (native Redshift connector)"
    from_port   = 5439
    to_port     = 5439
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "AWS service VPC endpoints (443) and the Zero-ETL data path to the source RDS instance"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-redshift" })
}
