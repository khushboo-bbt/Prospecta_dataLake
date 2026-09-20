# ---------------------------------------------------------------------------
# Maintenance job: reuses the same IAM role/permissions as the merge job
# (same S3 prefixes, same Glue Catalog databases) since rewrite_data_files/
# expire_snapshots need the same read/write access to the Iceberg tables.
# ---------------------------------------------------------------------------

resource "aws_s3_object" "iceberg_maintenance_job_script" {
  bucket = aws_s3_bucket.landing.bucket
  key    = "glue-scripts/iceberg_maintenance_job.py"

  source      = "${path.module}/scripts/iceberg_maintenance_job.py"
  source_hash = filemd5("${path.module}/scripts/iceberg_maintenance_job.py")

  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.poc2.arn

  tags = var.tags
}

resource "aws_glue_job" "iceberg_maintenance" {
  name              = "${var.name_prefix}-iceberg-maintenance"
  role_arn          = aws_iam_role.glue_iceberg_job.arn
  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 60

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.landing.bucket}/${aws_s3_object.iceberg_maintenance_job_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"             = "python"
    "--datalake-formats"         = "iceberg"
    "--TempDir"                  = "s3://${aws_s3_bucket.landing.bucket}/glue-temp/"
    "--target_database"          = aws_glue_catalog_database.curated.name
    "--table_configs"            = jsonencode(var.iceberg_table_configs)
    "--snapshot_retention_hours" = tostring(var.iceberg_snapshot_retention_hours)
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

# ---------------------------------------------------------------------------
# EventBridge Scheduler -> Glue StartJobRun, for both jobs.
#
# Classic EventBridge Rules (aws_cloudwatch_event_rule/_target) do NOT
# support Glue jobs as a target at all — PutTargets rejects a Glue job ARN
# with "Provided Arn is not in correct format" even though the ARN is
# well-formed, confirmed via a real apply attempt. EventBridge Scheduler's
# "universal target" (arn:aws:scheduler:::aws-sdk:<service>:<action>) is the
# AWS-documented way to call glue:StartJobRun on a schedule without a Lambda
# go-between.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "scheduler_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler_glue_trigger" {
  name               = "${var.name_prefix}-scheduler-glue-trigger"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "scheduler_glue_trigger" {
  statement {
    effect  = "Allow"
    actions = ["glue:StartJobRun"]
    resources = [
      aws_glue_job.iceberg_merge.arn,
      aws_glue_job.iceberg_maintenance.arn,
    ]
  }

  # Crawler ARNs use a different resource format than job ARNs
  # (arn:aws:glue:region:account:crawler/name) — separate statement, same
  # role, since StartCrawler isn't valid on a job ARN or vice versa.
  statement {
    effect    = "Allow"
    actions   = ["glue:StartCrawler"]
    resources = [aws_glue_crawler.poc2.arn]
  }
}

resource "aws_iam_role_policy" "scheduler_glue_trigger" {
  name   = "${var.name_prefix}-scheduler-glue-trigger"
  role   = aws_iam_role.scheduler_glue_trigger.id
  policy = data.aws_iam_policy_document.scheduler_glue_trigger.json
}

resource "aws_scheduler_schedule" "iceberg_merge" {
  name                = "${var.name_prefix}-iceberg-merge-schedule"
  schedule_expression = var.iceberg_merge_schedule

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:glue:startJobRun"
    role_arn = aws_iam_role.scheduler_glue_trigger.arn

    input = jsonencode({
      JobName = aws_glue_job.iceberg_merge.name
    })
  }
}

resource "aws_scheduler_schedule" "iceberg_maintenance" {
  name                = "${var.name_prefix}-iceberg-maintenance-schedule"
  schedule_expression = var.iceberg_maintenance_schedule

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:glue:startJobRun"
    role_arn = aws_iam_role.scheduler_glue_trigger.arn

    input = jsonencode({
      JobName = aws_glue_job.iceberg_maintenance.name
    })
  }
}

resource "aws_scheduler_schedule" "glue_crawler" {
  name                = "${var.name_prefix}-crawler-schedule"
  schedule_expression = var.glue_crawler_schedule

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:glue:startCrawler"
    role_arn = aws_iam_role.scheduler_glue_trigger.arn

    input = jsonencode({
      Name = aws_glue_crawler.poc2.name
    })
  }
}
