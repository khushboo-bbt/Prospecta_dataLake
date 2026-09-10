resource "aws_glue_catalog_database" "curated" {
  name        = var.iceberg_database_name
  description = "Curated, deduplicated Iceberg tables merged from the raw ${var.glue_database_name} landing-zone catalog."
}

resource "aws_s3_object" "iceberg_merge_job_script" {
  bucket      = aws_s3_bucket.landing.bucket
  key         = "glue-scripts/iceberg_merge_job.py"
  source      = "${path.module}/scripts/iceberg_merge_job.py"
  source_hash = filemd5("${path.module}/scripts/iceberg_merge_job.py")

  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.poc2.arn

  tags = var.tags
}

data "aws_iam_policy_document" "glue_job_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_iceberg_job" {
  name               = "${var.name_prefix}-glue-iceberg-job"
  assume_role_policy = data.aws_iam_policy_document.glue_job_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "glue_iceberg_job" {
  # Read the raw landing-zone data + read/write the new curated Iceberg
  # prefix, both in the same bucket.
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.landing.arn,
      "${aws_s3_bucket.landing.arn}/${var.landed_schema_prefix}/*",
      "${aws_s3_bucket.landing.arn}/iceberg/*",
      "${aws_s3_bucket.landing.arn}/glue-scripts/*",
      "${aws_s3_bucket.landing.arn}/glue-temp/*",
      "${aws_s3_bucket.landing.arn}/glue-bookmarks/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
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

  # Catalog access: read the raw database, full read/write on the curated one.
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
      aws_glue_catalog_database.curated.arn,
      "${aws_glue_catalog_database.curated.arn}/*",
      "arn:aws:glue:${var.aws_region}:*:table/${var.glue_database_name}/*",
      "arn:aws:glue:${var.aws_region}:*:table/${var.iceberg_database_name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "glue_iceberg_job" {
  name   = "${var.name_prefix}-glue-iceberg-job"
  role   = aws_iam_role.glue_iceberg_job.id
  policy = data.aws_iam_policy_document.glue_iceberg_job.json
}

resource "aws_glue_job" "iceberg_merge" {
  name              = "${var.name_prefix}-iceberg-merge"
  role_arn          = aws_iam_role.glue_iceberg_job.arn
  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 60

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.landing.bucket}/${aws_s3_object.iceberg_merge_job_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"           = "python"
    "--job-bookmark-option"    = "job-bookmark-enable"
    "--datalake-formats"       = "iceberg"
    "--TempDir"                = "s3://${aws_s3_bucket.landing.bucket}/glue-temp/"
    "--source_database"        = aws_glue_catalog_database.poc2.name
    "--target_database"        = aws_glue_catalog_database.curated.name
    "--iceberg_warehouse_path" = "s3://${aws_s3_bucket.landing.bucket}/iceberg/"
    "--table_configs"          = jsonencode(var.iceberg_table_configs)
    # Glue's --conf argument only accepts ONE key=value pair per literal
    # "--conf" — to pass several in the single map value Terraform allows
    # here, AWS's documented workaround is re-inserting the literal token
    # "--conf" between each pair inside the one string (Glue re-splits it).
    # A plain space-joined list of key=value pairs (no re-inserted "--conf")
    # fails at launch with "LAUNCH ERROR | Invalid input to --conf".
    "--conf" = join(" --conf ", [
      "spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
      "spark.sql.catalog.glue_catalog=org.apache.iceberg.spark.SparkCatalog",
      "spark.sql.catalog.glue_catalog.warehouse=s3://${aws_s3_bucket.landing.bucket}/iceberg/",
      "spark.sql.catalog.glue_catalog.catalog-impl=org.apache.iceberg.aws.glue.GlueCatalog",
      "spark.sql.catalog.glue_catalog.io-impl=org.apache.iceberg.aws.s3.S3FileIO",
    ])
  }

  tags = var.tags
}
