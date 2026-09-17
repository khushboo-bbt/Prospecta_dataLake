resource "aws_sns_topic" "zero_etl_health" {
  name              = "${var.name_prefix}-zero-etl-health"
  kms_master_key_id = aws_kms_key.poc3.id
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "zero_etl_health_email" {
  count = var.alarm_notification_email != null ? 1 : 0

  topic_arn = aws_sns_topic.zero_etl_health.arn
  protocol  = "email"
  endpoint  = var.alarm_notification_email
}

# ---------------------------------------------------------------------------
# Custom metric published by lambda/zero_etl_poller.py from
# SVV_INTEGRATION_TABLE_STATE — the count of in-scope tables whose
# table_state isn't "Synced" (Failed, Deleted, ResyncRequired,
# ResyncInitiated, DroppedSource all count as unhealthy). Alarms above zero,
# same period/evaluation shape as poc2's DMS alarms.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "unsynced_tables" {
  alarm_name          = "${var.name_prefix}-unsynced-tables"
  alarm_description   = "One or more in-scope tables are not in Synced state per SVV_INTEGRATION_TABLE_STATE — see the Lambda's CloudWatch Logs for schema/table/reason."
  namespace           = "Custom/ZeroETL"
  metric_name         = "UnsyncedTableCount"
  dimensions          = { IntegrationName = aws_rds_integration.poc3.integration_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.zero_etl_health.arn]
  ok_actions          = [aws_sns_topic.zero_etl_health.arn]
  tags                = var.tags
}

# The poller's own execution health — if its redshift-data query fails (e.g.
# run before sql/01_create_target_database.sql has created the destination
# database), the Lambda raises and UnsyncedTableCount never gets published at
# all, which treat_missing_data = "notBreaching" above would otherwise mask.
# Standard AWS/Lambda Errors metric, no custom publish needed for this one.
resource "aws_cloudwatch_metric_alarm" "poller_errors" {
  alarm_name          = "${var.name_prefix}-poller-errors"
  alarm_description   = "The sync-failure poller Lambda is erroring — check CloudWatch Logs at ${aws_cloudwatch_log_group.zero_etl_poller.name}."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.zero_etl_poller.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.zero_etl_health.arn]
  ok_actions          = [aws_sns_topic.zero_etl_health.arn]
  tags                = var.tags
}
