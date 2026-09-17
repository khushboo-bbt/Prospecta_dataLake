# manage_admin_password lets Redshift own the admin credential in its own
# Secrets Manager secret, rather than this module handling a password — same
# approach as poc1.
resource "aws_redshiftserverless_namespace" "poc3" {
  namespace_name = "${var.name_prefix}-namespace"

  admin_username        = "redshift_admin"
  manage_admin_password = true

  # The namespace's own database is the CONSUMER database (SOW: "consumer-
  # facing views and materialised views are built in a separate Amazon
  # Redshift database" since the destination database created FROM
  # INTEGRATION is read-only). The destination database itself is created by
  # sql/01_create_target_database.sql, not here — Redshift creates it once
  # the integration is Active, and no Terraform resource for CREATE DATABASE
  # ... FROM INTEGRATION exists in the AWS provider.
  db_name    = var.consumer_db_name
  kms_key_id = aws_kms_key.poc3.arn
  iam_roles  = [aws_iam_role.redshift_zero_etl.arn]

  tags = merge(var.tags, { Name = "${var.name_prefix}-namespace" })
}

resource "aws_redshiftserverless_workgroup" "poc3" {
  namespace_name = aws_redshiftserverless_namespace.poc3.namespace_name
  workgroup_name = "${var.name_prefix}-workgroup"

  base_capacity       = var.redshift_base_capacity
  publicly_accessible = false
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.redshift.id]

  # Same reasoning as poc1's redshift.tf: without this, Redshift routes data
  # traffic over the public AWS backbone instead of through this VPC.
  enhanced_vpc_routing = true

  # Same fixed-set gotcha documented in poc1's redshift.tf: Redshift Serverless
  # always carries this full set of workgroup config parameters, and a partial
  # declaration causes a perpetual no-op diff AWS itself rejects. Values below
  # mirror poc1's confirmed-via-`get-workgroup` defaults, with ONE required
  # difference: enable_case_sensitive_identifier MUST be "true" here — the
  # zero-ETL integration requires it (AWS RDS User Guide: "Turn on case
  # sensitivity for your data warehouse" — REDSHIFT-INTEGRATION-EVENT-1001
  # fails the integration outright if this is left at the default "false").
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
    parameter_value = "true"
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

  # See poc1's redshift.tf for the full explanation — AWS's real API always
  # returns an additional enable_large_strings_opt_in parameter this provider
  # version's schema rejects if declared explicitly.
  lifecycle {
    ignore_changes = [config_parameter]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-workgroup" })
}

# ---------------------------------------------------------------------------
# Resource policy authorising the source RDS instance to create/maintain an
# inbound integration into this namespace — set MANUALLY via the AWS CLI, not
# by a Terraform resource. aws_redshiftserverless_resource_policy is broken in
# hashicorp/aws 5.100.0 for any policy with more than one statement: AWS
# always stores/returns Statement as a JSON array (confirmed via `aws
# redshift-serverless get-resource-policy`, matching AWS's own documented
# two-statement sample verbatim, Resource keys included), but the provider's
# Go model for reading it back deserializes into a SINGLE iam.IAMPolicyStatement
# struct, not a slice — so every plan/refresh against this resource fails with
# "cannot unmarshal array into Go struct field resourcePolicyDoc.Statement",
# regardless of what shape is submitted. Confirmed across three real apply
# attempts (two statements, one statement with no Resource key, one statement
# as a bare object) — the first of the three actually succeeded in setting
# the correct, AWS-documented two-statement policy on the real namespace
# before the provider's own read-back failed and reported it as an error.
#
# Since the policy is already correctly set on the real namespace (verified
# via the CLI command below) and Terraform cannot manage this resource
# without erroring on every subsequent plan, it's intentionally NOT declared
# here. If this namespace is ever recreated, reapply it manually:
#
#   aws redshift-serverless put-resource-policy --region <aws_region> \
#     --resource-arn <redshift_namespace_arn output> \
#     --policy file://resource-policy.json
#
# where resource-policy.json contains the two-statement document from the
# AWS Redshift Management Guide ("Configure authorization for your Amazon
# Redshift data warehouse"): an AuthorizeInboundIntegration statement for the
# redshift.amazonaws.com service principal conditioned on aws:SourceArn =
# the source RDS instance's ARN, plus a CreateInboundIntegration statement.
#
# That second statement's Principal is NOT just the account root ARN, despite
# that being what AWS's own docs sample shows and what standard IAM resource-
# policy evaluation would suggest is sufficient for "any principal in this
# account". Confirmed via a real `aws rds create-integration` (via
# aws_rds_integration) failing against a root-ARN-only policy with
# "InvalidParameterValue: ... Check the resource policy of the data warehouse
# and make sure your user or role is specified as an authorized principal" —
# zero-ETL's own authorization check apparently requires the calling
# principal's actual role/user ARN to be listed explicitly, not just implied
# via the account root. resource-policy.json lists both the root ARN and the
# specific IAM Identity Center role ARN this account's operators assume
# (arn:...:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_Administrator_*)
# — add any other principal that needs to create integrations here too.
# ---------------------------------------------------------------------------

locals {
  source_db_arn = "arn:aws:rds:${var.aws_region}:${data.aws_caller_identity.current.account_id}:db:${var.source_db_instance_identifier}"
}
