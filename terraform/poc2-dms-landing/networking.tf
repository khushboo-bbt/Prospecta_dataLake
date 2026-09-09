resource "aws_security_group" "dms" {
  name        = "${var.name_prefix}-dms"
  description = "Security group for the POC2 DMS Serverless replication ENIs."
  vpc_id      = var.vpc_id

  egress {
    description = "Outbound to source DB and AWS service VPC endpoints (443)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-dms" })
}

resource "aws_dms_replication_subnet_group" "poc2" {
  replication_subnet_group_id          = "${var.name_prefix}-subnet-group"
  replication_subnet_group_description = "Private subnets for the POC2 DMS Serverless replication."
  subnet_ids                           = var.private_subnet_ids

  tags = var.tags
}

resource "aws_vpc_endpoint" "s3" {
  count             = var.create_s3_gateway_endpoint ? 1 : 0
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-s3-endpoint" })
}
