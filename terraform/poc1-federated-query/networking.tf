data "aws_region" "current" {}

# The shared foundation VPC (terraform/datalake-poc-foundation) is fully
# private — no NAT/internet gateway, only an S3 gateway endpoint and a fixed
# set of interface endpoints (secretsmanager, logs, kms, ssm, ssmmessages,
# ec2messages). ECS Fargate additionally needs ecr.api / ecr.dkr to pull the
# PgBouncer image from the private repo in ecr.tf — the S3 gateway endpoint
# already covers image layer storage, so only these two are new.
resource "aws_security_group" "ecr_endpoints" {
  count = var.create_ecr_vpc_endpoints ? 1 : 0

  name        = "${var.name_prefix}-ecr-endpoints"
  description = "Allows HTTPS from within the sandbox VPC to the ECR interface VPC endpoints."
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-ecr-endpoints" })
}

resource "aws_vpc_endpoint" "ecr" {
  for_each = var.create_ecr_vpc_endpoints ? toset(["api", "dkr"]) : []

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ecr.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.ecr_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-ecr-${each.value}-endpoint" })
}
