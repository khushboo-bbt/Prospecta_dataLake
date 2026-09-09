resource "aws_vpc" "datalake_poc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name_prefix })
}

resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.datalake_poc.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, { Name = "${var.name_prefix}-private-${var.availability_zones[count.index]}" })
}

# Single shared route table for all private subnets — no NAT/internet gateway;
# egress to AWS services is via the endpoints in endpoints.tf, and to the RDS
# instance via the peering connection in peering.tf.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.datalake_poc.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-private" })
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
