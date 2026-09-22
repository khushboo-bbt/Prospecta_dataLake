# See the note in variables.tf: this module adds its own IGW/NAT/subnets
# rather than touching the foundation module's shared private route table,
# so the internet egress the gateway genuinely needs stays scoped to just
# this one instance.

resource "aws_internet_gateway" "gateway" {
  vpc_id = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

# Nothing is launched directly into this subnet other than the NAT
# gateway's own ENI - map_public_ip_on_launch stays off.
resource "aws_subnet" "public" {
  vpc_id            = var.vpc_id
  cidr_block        = var.public_subnet_cidr
  availability_zone = var.availability_zone

  tags = merge(var.tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route_table" "public" {
  vpc_id = var.vpc_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gateway.id
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat" })

  depends_on = [aws_internet_gateway.gateway]
}

resource "aws_nat_gateway" "gateway" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat" })

  depends_on = [aws_internet_gateway.gateway]
}

# Private (no direct IGW route) - the gateway instance itself lives here,
# reaching the internet only via the NAT gateway above.
resource "aws_subnet" "gateway" {
  vpc_id            = var.vpc_id
  cidr_block        = var.gateway_subnet_cidr
  availability_zone = var.availability_zone

  tags = merge(var.tags, { Name = "${var.name_prefix}-gateway" })
}

resource "aws_route_table" "gateway" {
  vpc_id = var.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.gateway.id
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-gateway" })
}

resource "aws_route_table_association" "gateway" {
  subnet_id      = aws_subnet.gateway.id
  route_table_id = aws_route_table.gateway.id
}
