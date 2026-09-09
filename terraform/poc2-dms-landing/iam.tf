data "aws_iam_policy_document" "dms_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dms.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Account-wide DMS service roles. These are singletons per account/region and
# must exist with these exact names before a VPC-based replication (including
# DMS Serverless) can be created. Skip if another module/POC already created
# them (set create_dms_iam_service_roles = false).
# ---------------------------------------------------------------------------

resource "aws_iam_role" "dms_vpc_role" {
  count              = var.create_dms_iam_service_roles ? 1 : 0
  name               = "dms-vpc-role"
  assume_role_policy = data.aws_iam_policy_document.dms_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "dms_vpc_role" {
  count      = var.create_dms_iam_service_roles ? 1 : 0
  role       = aws_iam_role.dms_vpc_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
}

resource "aws_iam_role" "dms_cloudwatch_logs_role" {
  count              = var.create_dms_iam_service_roles ? 1 : 0
  name               = "dms-cloudwatch-logs-role"
  assume_role_policy = data.aws_iam_policy_document.dms_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "dms_cloudwatch_logs_role" {
  count      = var.create_dms_iam_service_roles ? 1 : 0
  role       = aws_iam_role.dms_cloudwatch_logs_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSCloudWatchLogsRole"
}

# ---------------------------------------------------------------------------
# S3 target endpoint role: least-privilege access to the landing bucket + KMS key
# ---------------------------------------------------------------------------

resource "aws_iam_role" "dms_s3_target" {
  name               = "${var.name_prefix}-dms-s3-target"
  assume_role_policy = data.aws_iam_policy_document.dms_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "dms_s3_target" {
  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.landing.arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.landing.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.poc2.arn]
  }
}

resource "aws_iam_role_policy" "dms_s3_target" {
  name   = "${var.name_prefix}-dms-s3-target"
  role   = aws_iam_role.dms_s3_target.id
  policy = data.aws_iam_policy_document.dms_s3_target.json
}

# ---------------------------------------------------------------------------
# Source endpoint role: read the DB credential secret
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "dms_secrets_access_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      # A source endpoint using secrets_manager_access_role_arn requires the
      # DMS *regional* service principal here, not just dms.amazonaws.com —
      # AWS DMS rejects endpoint creation otherwise (the other DMS roles in
      # this file don't need this, only this one, since only this role backs
      # a secrets_manager_access_role_arn).
      identifiers = ["dms.amazonaws.com", "dms.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dms_secrets_access" {
  name               = "${var.name_prefix}-dms-secrets-access"
  assume_role_policy = data.aws_iam_policy_document.dms_secrets_access_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "dms_secrets_access" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.source_db.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.poc2.arn]
  }
}

resource "aws_iam_role_policy" "dms_secrets_access" {
  name   = "${var.name_prefix}-dms-secrets-access"
  role   = aws_iam_role.dms_secrets_access.id
  policy = data.aws_iam_policy_document.dms_secrets_access.json
}
