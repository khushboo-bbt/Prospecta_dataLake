data "aws_ami" "windows" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "gateway" {
  key_name   = "${var.name_prefix}-gateway"
  public_key = var.gateway_key_pair_public_key

  tags = var.tags
}

resource "aws_instance" "gateway" {
  ami                    = data.aws_ami.windows.id
  instance_type          = var.gateway_instance_type
  subnet_id              = aws_subnet.gateway.id
  vpc_security_group_ids = [aws_security_group.gateway.id]
  iam_instance_profile   = aws_iam_instance_profile.gateway.name
  key_name               = aws_key_pair.gateway.key_name

  # No public IP - outbound internet comes from the NAT gateway in
  # networking.tf, and admin access is via SSM Session Manager port
  # forwarding (see README.md), not direct RDP.
  associate_public_ip_address = false

  root_block_device {
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  # data.aws_ami.windows uses most_recent = true, which re-resolves to
  # whatever AMI AWS has published as of *this* plan - unrelated to any
  # change actually being made here. Same reasoning/pattern as the
  # foundation module's bastion: don't let an unrelated apply silently
  # replace a gateway that's been manually configured (Power BI sign-in,
  # recovery key, ODBC driver) - bump the AMI deliberately (remove this
  # ignore temporarily) if it's ever actually time to move to a newer one.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-gateway" })
}
