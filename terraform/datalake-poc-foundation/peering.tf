# Same-account, same-region peering (ap-southeast-1) to the existing RDS VPC
# (vpc-primary-fuse-intenal). auto_accept works here because both sides are
# owned by this account in the same region.
resource "aws_vpc_peering_connection" "to_rds_vpc" {
  vpc_id      = aws_vpc.datalake_poc.id
  peer_vpc_id = var.rds_vpc_id
  auto_accept = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-to-rds-vpc" })
}

# Our side: route to the RDS VPC. This is our own new route table, so this is
# a full route table entry, not a standalone addition to someone else's table.
resource "aws_route" "to_rds_vpc" {
  route_table_id            = aws_route_table.private.id
  destination_cidr_block    = var.rds_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.to_rds_vpc.id
}

# Existing side (RDS's own route table, rtb-044115b113e436552): additive-only
# standalone route. This does NOT adopt or manage the rest of that route
# table — it only ensures this one route exists, alongside the NAT gateway,
# S3 gateway endpoint, and existing eks-fuse-internal peering route already
# there.
resource "aws_route" "rds_vpc_to_datalake_poc" {
  route_table_id            = var.rds_route_table_id
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.to_rds_vpc.id
}

# Existing side (RDS's security group, sg-069103bcb5acbd88d): additive-only
# standalone ingress rule. This does NOT adopt or manage the rest of that
# security group's rules — it only adds this one rule, alongside the existing
# 10.70.1.0/24 and 10.40.0.0/16 (sydney-vpc) rules.
resource "aws_security_group_rule" "rds_allow_datalake_poc" {
  type              = "ingress"
  security_group_id = var.rds_security_group_id
  from_port         = var.rds_port
  to_port           = var.rds_port
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  description       = "DataLake POC VPC (${var.name_prefix}) - DMS access"
}
