locals {
  # Confirmed empirically via `aws cloudwatch list-metrics` — DMS Serverless
  # publishes this dimension as "<account_id>:<replication_config_identifier>",
  # not the config's ARN or a separate generated ID.
  dms_replication_config_dimension = "${data.aws_caller_identity.current.account_id}:${aws_dms_replication_config.poc2.replication_config_identifier}"
}

resource "aws_sns_topic" "replica_health" {
  name              = "${var.name_prefix}-replica-health"
  kms_master_key_id = aws_kms_key.poc2.id
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "replica_health_email" {
  count = var.alarm_notification_email != null ? 1 : 0

  topic_arn = aws_sns_topic.replica_health.arn
  protocol  = "email"
  endpoint  = var.alarm_notification_email
}

# ---------------------------------------------------------------------------
# DMS-side: is replication itself falling behind?
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cdc_latency_source" {
  alarm_name          = "${var.name_prefix}-cdc-latency-source"
  alarm_description   = "DMS is falling behind reading changes from the source WAL."
  namespace           = "AWS/DMS"
  metric_name         = "CDCLatencySource"
  dimensions          = { ReplicationConfigId = local.dms_replication_config_dimension }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.cdc_latency_threshold_seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.replica_health.arn]
  ok_actions          = [aws_sns_topic.replica_health.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "cdc_latency_target" {
  alarm_name          = "${var.name_prefix}-cdc-latency-target"
  alarm_description   = "DMS is falling behind writing captured changes to the S3 target."
  namespace           = "AWS/DMS"
  metric_name         = "CDCLatencyTarget"
  dimensions          = { ReplicationConfigId = local.dms_replication_config_dimension }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.cdc_latency_threshold_seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.replica_health.arn]
  ok_actions          = [aws_sns_topic.replica_health.arn]
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Source RDS-side: is the replication slot healthy? This matters more than
# the DMS-side metrics given postgreslt hosts ~28 other databases — an
# unhealthy/stalled slot accumulates WAL that affects everything else on
# the shared instance, not just this POC.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "replication_slot_disk_usage" {
  alarm_name          = "${var.name_prefix}-replication-slot-disk-usage"
  alarm_description   = "The logical replication slot is retaining more WAL than expected — likely stalled/stopped CDC, accumulating disk usage shared by all databases on postgreslt."
  namespace           = "AWS/RDS"
  metric_name         = "ReplicationSlotDiskUsage"
  dimensions          = { DBInstanceIdentifier = var.source_db_instance_identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.replication_slot_disk_usage_threshold_mb
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.replica_health.arn]
  ok_actions          = [aws_sns_topic.replica_health.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "oldest_replication_slot_lag" {
  alarm_name          = "${var.name_prefix}-oldest-replication-slot-lag"
  alarm_description   = "The slowest replication slot on postgreslt has fallen behind by more than the threshold."
  namespace           = "AWS/RDS"
  metric_name         = "OldestReplicationSlotLag"
  dimensions          = { DBInstanceIdentifier = var.source_db_instance_identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.oldest_replication_slot_lag_threshold_mb
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.replica_health.arn]
  ok_actions          = [aws_sns_topic.replica_health.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "transaction_logs_disk_usage" {
  alarm_name          = "${var.name_prefix}-transaction-logs-disk-usage"
  alarm_description   = "Total WAL disk usage on postgreslt is higher than expected — affects all ~28 databases on this shared instance, not just this POC."
  namespace           = "AWS/RDS"
  metric_name         = "TransactionLogsDiskUsage"
  dimensions          = { DBInstanceIdentifier = var.source_db_instance_identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.transaction_logs_disk_usage_threshold_mb
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.replica_health.arn]
  ok_actions          = [aws_sns_topic.replica_health.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "free_storage_space" {
  alarm_name          = "${var.name_prefix}-free-storage-space"
  alarm_description   = "postgreslt is running low on free storage — shared by all ~28 databases on this instance."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.source_db_instance_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = var.free_storage_space_threshold_bytes
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.replica_health.arn]
  ok_actions          = [aws_sns_topic.replica_health.arn]
  tags                = var.tags
}
