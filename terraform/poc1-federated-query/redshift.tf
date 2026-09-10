resource "aws_security_group" "redshift" {
  name        = "${var.name_prefix}-redshift"
  description = "Redshift Serverless workgroup for POC1. Egress to PgBouncer only, plus AWS service VPC endpoints."
  vpc_id      = var.vpc_id

  egress {
    description = "PgBouncer, plus AWS service VPC endpoints (443)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-redshift" })
}

# manage_admin_password lets Redshift own the admin credential in its own
# Secrets Manager secret, rather than this module handling a third password.
resource "aws_redshiftserverless_namespace" "poc1" {
  namespace_name = "${var.name_prefix}-namespace"

  admin_username        = "redshift_admin"
  manage_admin_password = true

  db_name    = "poc1_federated_query"
  kms_key_id = aws_kms_key.poc1.arn
  iam_roles  = [aws_iam_role.redshift_federated_query.arn]

  tags = merge(var.tags, { Name = "${var.name_prefix}-namespace" })
}

resource "aws_redshiftserverless_workgroup" "poc1" {
  namespace_name = aws_redshiftserverless_namespace.poc1.namespace_name
  workgroup_name = "${var.name_prefix}-workgroup"

  base_capacity       = var.redshift_base_capacity
  publicly_accessible = false
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.redshift.id]

  # Closest native equivalent to the SOW's WLM query monitoring rule —
  # Redshift Serverless does not expose classic WLM. See README.
  #
  # NOTE: the AWS provider has a known quirk where specifying only a subset
  # of config_parameter blocks can show a diff on every plan, because the API
  # returns the full set of parameters (including untouched defaults) back in
  # state. Run `terraform plan` twice after the first apply; if a persistent
  # diff appears, add explicit config_parameter blocks for the remaining
  # defaults (datestyle, enable_user_activity_logging, query_group,
  # search_path, require_ssl, use_fips_ssl) matching what AWS reports.
  config_parameter {
    parameter_key   = "max_query_execution_time"
    parameter_value = tostring(var.redshift_max_query_execution_time_seconds)
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-workgroup" })
}
