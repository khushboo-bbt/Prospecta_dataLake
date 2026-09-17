# ---------------------------------------------------------------------------
# Redshift namespace IAM role. Minimal — the namespace itself needs no
# external-schema/Secrets Manager access like poc1's (there's no federated
# query here), just permission to use the KMS key for data encrypted at rest.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "redshift_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["redshift.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "redshift_zero_etl" {
  name               = "${var.name_prefix}-redshift-zero-etl"
  assume_role_policy = data.aws_iam_policy_document.redshift_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "redshift_zero_etl" {
  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.poc3.arn]
  }
}

resource "aws_iam_role_policy" "redshift_zero_etl" {
  name   = "${var.name_prefix}-redshift-zero-etl"
  role   = aws_iam_role.redshift_zero_etl.id
  policy = data.aws_iam_policy_document.redshift_zero_etl.json
}

# ---------------------------------------------------------------------------
# Sync-failure poller Lambda execution role. Polls SVV_INTEGRATION_TABLE_STATE
# via the Redshift Data API (authenticating with the namespace's own
# Redshift-managed admin secret, not a Postgres login) and publishes a custom
# CloudWatch metric. No VPC access needed — both the Data API and CloudWatch
# are regional AWS service APIs, not VPC-bound.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "zero_etl_poller" {
  name               = "${var.name_prefix}-zero-etl-poller"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "zero_etl_poller_basic_execution" {
  role       = aws_iam_role.zero_etl_poller.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "zero_etl_poller" {
  # Only ExecuteStatement supports resource-level scoping to a workgroup.
  statement {
    effect    = "Allow"
    actions   = ["redshift-data:ExecuteStatement"]
    resources = [aws_redshiftserverless_workgroup.poc3.arn]
  }

  # DescribeStatement/GetStatementResult act on a statement ID, not a
  # workgroup, and AWS does not support resource-level permissions for them —
  # scoping these to the workgroup ARN denies them outright ("not authorized
  # to perform: redshift-data:DescribeStatement because no identity-based
  # policy allows..."), confirmed via a real Lambda invocation.
  #
  # A redshift-data:statement-owner-iam-userid condition (restricting this to
  # statements the role itself submitted) was tried here and still produced
  # the same denial, so it is deliberately omitted. The Data API already
  # restricts these calls to statements submitted by the same principal, so
  # the practical exposure of Resource = "*" here is limited.
  statement {
    effect = "Allow"
    actions = [
      "redshift-data:DescribeStatement",
      "redshift-data:GetStatementResult",
    ]
    resources = ["*"]
  }

  # The Data API assumes this role's permissions to retrieve the admin secret
  # itself when secrets_manager_arn is used instead of temporary credentials
  # (same pattern as poc1's mv_refresh.tf EventBridge role).
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_redshiftserverless_namespace.poc3.admin_password_secret_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData does not support resource-level restriction
  }
}

resource "aws_iam_role_policy" "zero_etl_poller" {
  name   = "${var.name_prefix}-zero-etl-poller"
  role   = aws_iam_role.zero_etl_poller.id
  policy = data.aws_iam_policy_document.zero_etl_poller.json
}
