# ---------------------------------------------------------------------------
# Register the curated data's S3 location with Lake Formation. Uses Lake
# Formation's own service-linked role for S3 access (no role_arn specified).
# ---------------------------------------------------------------------------

resource "aws_lakeformation_resource" "curated" {
  arn = "${aws_s3_bucket.landing.arn}/iceberg"
}

# ---------------------------------------------------------------------------
# Restricted consumer: a dedicated IAM user for external tools (Power BI)
# that only ever needs read access to the curated, business-ready Iceberg
# tables — never the raw landing zone (DMS bookkeeping columns, dynamic
# per-tenant schemas, system tables like databasechangelog).
#
# This is additive only: scoping THIS user's own IAM policy to just the
# curated database/prefix achieves real segregation without touching any
# existing grant (e.g. Lake Formation's IAMAllowedPrincipals default on
# datalake_poc2/datalake_poc2_curated), so nothing already working —
# crawler, merge job — is at any risk of being disturbed.
# ---------------------------------------------------------------------------

resource "aws_iam_user" "curated_reader" {
  name = "${var.name_prefix}-curated-reader"
  tags = var.tags
}

resource "aws_iam_access_key" "curated_reader" {
  user = aws_iam_user.curated_reader.name
}

data "aws_iam_policy_document" "curated_reader" {
  statement {
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution",
      "athena:GetWorkGroup",
    ]
    resources = [aws_athena_workgroup.poc2.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:*:catalog",
      aws_glue_catalog_database.curated.arn,
      "${aws_glue_catalog_database.curated.arn}/*",
      "arn:aws:glue:${var.aws_region}:*:table/${var.iceberg_database_name}/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketLocation", # Athena needs this to "verify" the results bucket, distinct from ListBucket/GetObject
    ]
    resources = [
      aws_s3_bucket.landing.arn,
      "${aws_s3_bucket.landing.arn}/iceberg/*",
      "${aws_s3_bucket.landing.arn}/athena-results/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.landing.arn}/athena-results/*"]
  }

  # Separate from the Lake Formation SELECT/DESCRIBE grants themselves —
  # this is the action that lets this principal request the temporary,
  # scoped S3 credentials Lake Formation vends for reading a governed
  # table's underlying data. Without it, LF grants exist but the actual
  # data read fails with "not authorized to perform: lakeformation:GetDataAccess".
  statement {
    effect    = "Allow"
    actions   = ["lakeformation:GetDataAccess"]
    resources = ["*"]
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

resource "aws_iam_user_policy" "curated_reader" {
  name   = "${var.name_prefix}-curated-reader"
  user   = aws_iam_user.curated_reader.name
  policy = data.aws_iam_policy_document.curated_reader.json
}

resource "aws_lakeformation_permissions" "curated_reader" {
  principal = aws_iam_user.curated_reader.arn
  # SELECT is not a valid database-level permission in Lake Formation — only
  # applies to tables (see curated_reader_tables below, which already has
  # it). DESCRIBE is what lets this principal see the database/list tables.
  permissions = ["DESCRIBE"]

  database {
    name = aws_glue_catalog_database.curated.name
  }
}

resource "aws_lakeformation_permissions" "curated_reader_tables" {
  principal   = aws_iam_user.curated_reader.arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.curated.name
    wildcard      = true
  }
}
