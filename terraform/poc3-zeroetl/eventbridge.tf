# ---------------------------------------------------------------------------
# SOW: "two independent sync-failure detection paths ... Both are required
# because Amazon RDS publishes no integration metrics to CloudWatch and
# tables can fail to synchronise without raising an error." The shared SNS
# topic both paths (and the custom-metric alarm in monitoring.tf) publish to
# is defined there, not here.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "zero_etl_health_topic" {
  statement {
    effect  = "Allow"
    actions = ["sns:Publish"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sns_topic.zero_etl_health.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.integration_state.arn]
    }
  }
}

resource "aws_sns_topic_policy" "zero_etl_health" {
  arn    = aws_sns_topic.zero_etl_health.arn
  policy = data.aws_iam_policy_document.zero_etl_health_topic.json
}

# ---------------------------------------------------------------------------
# Path 1: EventBridge rule on the integration's own state-change events.
#
# Pattern CONFIRMED via a real captured event (2026-09-17), by adding an
# unsupported-data-type column (text > 64KB) to a disposable test table and
# catching the resulting notification with a temporary catch-all rule
# (source ["aws.redshift","aws.rds"], no detail-type filter) targeting a
# CloudWatch Logs group:
#
#   {
#     "detail-type": "Redshift Integration Monitoring",
#     "source": "aws.redshift",
#     "resources": ["<integration ARN>"],
#     "detail": {
#       "severity": "Info",
#       "sourceArn": "<source RDS ARN>",
#       "destinationArn": "<Redshift namespace ARN>",
#       "eventDescription": "Your zero-ETL Integration ... is synchronizing
#         transactional data to the Amazon Redshift data warehouse.",
#       "integrationStatus": "SYNCING",
#       "statusCode": "SYNCING"
#     }
#   }
#
# This matches REDSHIFT-INTEGRATION-EVENT-0003 from the documented catalogue
# (Redshift Management Guide, "Zero-ETL integration event notifications with
# Amazon EventBridge") exactly, confirming the source/detail-type documented
# there were never the actual values — "source" was right, "detail-type" was
# guessed wrong ("Redshift Integration Event" vs the real
# "Redshift Integration Monitoring").
#
# Filtered to Warning/Error severity only — Info-level events (like the one
# captured above) fire routinely during normal sync activity and would make
# this path noise rather than a failure signal. The Warning/Error casing is
# not a guess either: the same diagnostic test, once the oversized value
# actually caused the table to fail, produced a second real event with
# severity "Warning" (matching REDSHIFT-INTEGRATION-EVENT-0005/"unsupported
# data type" from the catalogue, statusCode "DATA_COLUMN_LENGTH_EXCEEDED",
# integrationStatus "NEEDS_ATTENTION"). This rule's filter values are
# therefore confirmed against a real failure, not inferred.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "integration_state" {
  name        = "${var.name_prefix}-integration-state"
  description = "Zero-ETL integration state-change events (Warning/Error severity only) — pattern confirmed via captured event, see eventbridge.tf comment."

  event_pattern = jsonencode({
    source      = ["aws.redshift"]
    detail-type = ["Redshift Integration Monitoring"]
    detail = {
      severity = ["Warning", "Error"]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "integration_state_sns" {
  rule      = aws_cloudwatch_event_rule.integration_state.name
  target_id = "${var.name_prefix}-integration-state-sns"
  arn       = aws_sns_topic.zero_etl_health.arn
}

# ---------------------------------------------------------------------------
# Path 2: scheduled invocation of the SVV_INTEGRATION_TABLE_STATE poller.
# Classic EventBridge Rule -> Lambda targeting is natively supported (unlike
# poc2's Glue case, which needed EventBridge Scheduler's universal target
# because PutTargets rejects a Glue job ARN outright).
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "poller_schedule" {
  name                = "${var.name_prefix}-poller-schedule"
  schedule_expression = var.poller_schedule
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "poller_schedule" {
  rule      = aws_cloudwatch_event_rule.poller_schedule.name
  target_id = "${var.name_prefix}-poller-schedule"
  arn       = aws_lambda_function.zero_etl_poller.arn
}

resource "aws_lambda_permission" "allow_eventbridge_poller_schedule" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.zero_etl_poller.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.poller_schedule.arn
}
