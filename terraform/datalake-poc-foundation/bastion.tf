# Temporary bastion for one-off admin access to the private RDS instance
# (e.g. creating the DMS replication DB user) via SSM Session Manager port
# forwarding. No SSH, no public IP, no inbound security group rules at all —
# the SSM agent connects outbound-only through the ssm/ssmmessages/ec2messages
# interface endpoints already added in endpoints.tf.

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_iam_policy_document" "bastion_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  name               = "${var.name_prefix}-bastion"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.name_prefix}-bastion"
  role = aws_iam_role.bastion.name
}

resource "aws_security_group" "bastion" {
  name        = "${var.name_prefix}-bastion"
  description = "No inbound. Outbound only to the VPC endpoints (443) and the RDS VPC (5432)."
  vpc_id      = aws_vpc.datalake_poc.id

  egress {
    description = "HTTPS to VPC interface endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Postgres to the peered RDS VPC"
    from_port   = var.rds_port
    to_port     = var.rds_port
    protocol    = "tcp"
    cidr_blocks = [var.rds_vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-bastion" })
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = false

  root_block_device {
    encrypted = true
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-bastion" })
}
