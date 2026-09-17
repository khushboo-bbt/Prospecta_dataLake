data "archive_file" "zero_etl_poller" {
  type        = "zip"
  source_file = "${path.module}/lambda/zero_etl_poller.py"
  output_path = "${path.module}/lambda/zero_etl_poller.zip"
}

resource "aws_cloudwatch_log_group" "zero_etl_poller" {
  name              = "/aws/lambda/${var.name_prefix}-zero-etl-poller"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.poc3.arn
  tags              = var.tags
}

resource "aws_lambda_function" "zero_etl_poller" {
  function_name = "${var.name_prefix}-zero-etl-poller"
  role          = aws_iam_role.zero_etl_poller.arn

  filename         = data.archive_file.zero_etl_poller.output_path
  source_code_hash = data.archive_file.zero_etl_poller.output_base64sha256

  handler = "zero_etl_poller.handler"
  runtime = "python3.12"
  timeout = var.poller_timeout_seconds

  # No VPC config: the Redshift Data API and CloudWatch PutMetricData are
  # both regional AWS service APIs, not VPC-bound, so there's no need to
  # attach this to the sandbox VPC (which also avoids ENI cold-start latency
  # and needing a redshift-data VPC endpoint).
  environment {
    variables = {
      WORKGROUP_NAME   = aws_redshiftserverless_workgroup.poc3.workgroup_name
      DATABASE         = var.consumer_db_name
      SECRET_ARN       = aws_redshiftserverless_namespace.poc3.admin_password_secret_arn
      TARGET_DATABASE  = var.destination_db_name
      INTEGRATION_NAME = aws_rds_integration.poc3.integration_name
    }
  }

  depends_on = [
    aws_iam_role_policy.zero_etl_poller,
    aws_iam_role_policy_attachment.zero_etl_poller_basic_execution,
    aws_cloudwatch_log_group.zero_etl_poller,
  ]

  tags = merge(var.tags, { Name = "${var.name_prefix}-zero-etl-poller" })
}
