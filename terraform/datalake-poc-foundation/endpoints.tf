data "aws_region" "current" {}

# Free — no hourly charge. Covers DMS's S3 landing-zone traffic for any POC
# using this VPC.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.datalake_poc.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.tags, { Name = "${var.name_prefix}-s3-endpoint" })
}

resource "aws_security_group" "interface_endpoints" {
  name        = "${var.name_prefix}-endpoints"
  description = "Allows HTTPS from within the DataLake POC VPC to the interface VPC endpoints."
  vpc_id      = aws_vpc.datalake_poc.id

  ingress {
    description = "HTTPS from within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-endpoints" })
}

locals {
  # ssm/ssmmessages/ec2messages are needed for Session Manager access to the
  # bastion instance in bastion.tf — no internet/NAT required either way.
  interface_endpoint_services = ["secretsmanager", "logs", "kms", "ssm", "ssmmessages", "ec2messages"]
}

# Keeps the VPC fully private (no NAT/internet gateway) while still letting
# DMS (or any future POC workload here) reach Secrets Manager, CloudWatch
# Logs, and KMS. Small hourly cost per service per AZ.
resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoint_services)

  vpc_id              = aws_vpc.datalake_poc.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.interface_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.value}-endpoint" })
}
