resource "aws_glue_catalog_database" "poc2" {
  name        = var.glue_database_name
  description = "Catalog for DMS-landed data from postgreslt.${var.source_db_name}.${var.landed_schema_prefix}"
}

data "aws_iam_policy_document" "glue_crawler_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_crawler" {
  name               = "${var.name_prefix}-glue-crawler"
  assume_role_policy = data.aws_iam_policy_document.glue_crawler_assume_role.json
  tags               = var.tags
}

# Least-privilege: read-only on just this bucket/prefix + decrypt on the
# same CMK the bucket is encrypted with, plus what AWSGlueServiceRole would
# otherwise grant broadly (CloudWatch Logs for crawler run output).
data "aws_iam_policy_document" "glue_crawler" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.landing.arn,
      "${aws_s3_bucket.landing.arn}/${var.landed_schema_prefix}/*",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.poc2.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${var.aws_region}:*:log-group:/aws-glue/*"]
  }

  # Catalog metadata access — separate from the S3 data access above.
  # Missing this causes the crawler to fail immediately with
  # "not authorized to perform: glue:GetDatabase".
  statement {
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:BatchCreatePartition",
      "glue:BatchGetPartition",
      "glue:BatchDeletePartition",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:UpdatePartition",
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:*:catalog",
      aws_glue_catalog_database.poc2.arn,
      "${aws_glue_catalog_database.poc2.arn}/*",
      "arn:aws:glue:${var.aws_region}:*:table/${var.glue_database_name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "glue_crawler" {
  name   = "${var.name_prefix}-glue-crawler"
  role   = aws_iam_role.glue_crawler.id
  policy = data.aws_iam_policy_document.glue_crawler.json
}

# Scheduled (eventbridge.tf) rather than on-demand — needs to run ahead of
# the Iceberg merge job so a newly-added source column reaches this catalog,
# and gets picked up by the merge job's schema-reconciliation step, before
# CDC files carrying that column actually arrive.
resource "aws_glue_crawler" "poc2" {
  name          = "${var.name_prefix}-crawler"
  role          = aws_iam_role.glue_crawler.arn
  database_name = aws_glue_catalog_database.poc2.name

  s3_target {
    path = "s3://${aws_s3_bucket.landing.bucket}/${var.landed_schema_prefix}/"
  }

  # Parquet schemas can vary slightly between the full-load LOAD* files and
  # later CDC files for the same table (e.g. added columns) — merge rather
  # than treating every difference as a new table version.
  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  tags = var.tags
}
