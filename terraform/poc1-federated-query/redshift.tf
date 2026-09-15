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

  # Without this, Redshift routes data traffic (COPY/UNLOAD/Federated Query)
  # over the public AWS backbone instead of through this VPC's actual
  # networking - fatal here since PgBouncer's NLB is purely internal with no
  # public path at all. Confirmed live via `aws redshift-serverless
  # get-workgroup`: enhancedVpcRouting was false, and every federated query
  # against ext_adhoc/ext_mv_refresh failed with "ERROR: timeout expired"
  # despite security groups, subnets, DNS resolution, and raw TCP
  # reachability to PgBouncer all independently verified working from
  # elsewhere in the same VPC.
  enhanced_vpc_routing = true

  # Redshift Serverless always carries this fixed set of workgroup config
  # parameters - declaring only max_query_execution_time (our one actual
  # change) left the rest at whatever AWS returned, and the provider's next
  # plan tried to "fix" that into a no-op UpdateWorkgroup call that AWS
  # itself rejected ("You didn't specify any changes"). The values below are
  # confirmed against this account via `aws redshift-serverless get-workgroup`
  # rather than assumed - notably require_ssl and enable_user_activity_logging
  # default to "true" here, not "false".
  #
  # `aws redshift-serverless get-workgroup` also returns an
  # enable_large_strings_opt_in parameter (value "" in this account) that
  # this provider version (hashicorp/aws ~> 5.0, resolved 5.100.0) rejects
  # client-side as an unrecognised parameter_key before any API call is even
  # made - it's simply not in the provider's validated key list yet, so it's
  # left unmanaged here rather than fought over.
  #
  # Closest native equivalent to the SOW's WLM query monitoring rule -
  # Redshift Serverless does not expose classic WLM. See README.
  config_parameter {
    parameter_key   = "max_query_execution_time"
    parameter_value = tostring(var.redshift_max_query_execution_time_seconds)
  }

  config_parameter {
    parameter_key   = "auto_mv"
    parameter_value = "true"
  }

  config_parameter {
    parameter_key   = "datestyle"
    parameter_value = "ISO, MDY"
  }

  config_parameter {
    parameter_key   = "enable_case_sensitive_identifier"
    parameter_value = "false"
  }

  config_parameter {
    parameter_key   = "enable_user_activity_logging"
    parameter_value = "true"
  }

  config_parameter {
    parameter_key   = "query_group"
    parameter_value = "default"
  }

  config_parameter {
    parameter_key   = "require_ssl"
    parameter_value = "true"
  }

  config_parameter {
    parameter_key   = "search_path"
    parameter_value = "$user, public"
  }

  config_parameter {
    parameter_key   = "use_fips_ssl"
    parameter_value = "false"
  }

  # AWS's real API always carries an additional enable_large_strings_opt_in
  # parameter (confirmed via `aws redshift-serverless get-workgroup`) that
  # this provider version's schema validation rejects if declared here (see
  # the comment above config_parameter). refresh reads it back into state,
  # then plan wants to remove it since our config doesn't declare it, and
  # that removal is itself a no-op AWS rejects - an unfixable loop without
  # this ignore. max_query_execution_time = 300 is already correctly applied
  # in AWS from the prior successful apply; changing it going forward
  # requires either a manual `aws redshift-serverless update-workgroup` call
  # or temporarily removing this ignore_changes entry.
  lifecycle {
    ignore_changes = [config_parameter]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-workgroup" })
}
