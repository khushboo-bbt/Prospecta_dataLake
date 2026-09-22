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

# This user's access key is NOT managed here (deliberately, as of a mid-POC
# rotation on 2026-09-22 done directly via `aws iam create-access-key` /
# `delete-access-key`) — an `aws_iam_access_key` resource's secret can only
# ever be read once, at creation, so Terraform has no way to track "the
# current live key" across an out-of-band rotation without silently
# generating a brand new one (and invalidating whatever's actually
# configured in the Power BI gateway's Athena DSN right now) on the next
# apply. Rotate with the AWS CLI directly:
#   aws iam create-access-key --user-name datalake-poc2-curated-reader
#   # update the DSN / Power BI connection with the new pair, confirm it works
#   aws iam delete-access-key --user-name datalake-poc2-curated-reader --access-key-id <old-id>

data "aws_iam_policy_document" "curated_reader" {
  statement {
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution",
      "athena:GetWorkGroup",
      # Distinct from GetQueryResults - this is the action the ODBC/JDBC
      # drivers' result-streaming path uses specifically (over port 444, see
      # the gateway security group), not the paginated API call the AWS CLI
      # uses. Missing this (and the port) is exactly why the raw CLI query
      # succeeded earlier while the same query through the ODBC driver hung
      # with an S3ClientError timeout.
      "athena:GetQueryResultsStream",
    ]
    resources = [aws_athena_workgroup.poc2.arn]
  }

  # ListDataCatalogs is account/region-scoped - no catalog-level ARN exists
  # to restrict it further (AWS's own managed Athena policies grant it
  # against Resource "*" too). Needed for Power BI's ODBC navigator to
  # enumerate catalogs before drilling into a specific database/table -
  # confirmed needed via a real connection attempt: "AccessDeniedException
  # ... athena:ListDataCatalogs".
  statement {
    effect    = "Allow"
    actions   = ["athena:ListDataCatalogs"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      # GetDatabases (plural) is what actually populates the navigator's
      # database list under AwsDataCatalog - GetDatabase (singular) alone
      # only fetches one already-known database by name. Same class of gap
      # as athena:ListDataCatalogs above: confirmed via a real connection
      # attempt showing an empty catalog rather than datalake_poc2_curated.
      "glue:GetDatabases",
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
  # Matches what's actually granted live today (confirmed via `terraform
  # plan`: -/+ replace, revoking ["ALL","DESCRIBE"] down to ["DESCRIBE"]).
  # A tighter, DESCRIBE-only grant is the eventual intent (SELECT isn't a
  # valid database-level permission — only applies to tables, see
  # curated_reader_tables below, which already has it — so DESCRIBE alone
  # is theoretically sufficient), but Lake Formation permission changes
  # replace rather than update in place, meaning a revoke-then-regrant with
  # a brief window of zero database-level access for this principal.
  # Deliberately left matching live state for now rather than bundled into
  # unrelated work — tighten this in its own change, at a moment nothing is
  # actively querying through curated_reader.
  permissions = ["ALL", "DESCRIBE"]

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
