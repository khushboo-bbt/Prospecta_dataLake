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
# AWS documents the full catalogue of zero-ETL integration event IDs
# (REDSHIFT-INTEGRATION-EVENT-0000 through 1006 — Redshift Management Guide,
# "Zero-ETL integration event notifications with Amazon EventBridge"), but
# the exact EventBridge `source`/`detail-type` strings Redshift Serverless
# actually emits for these were not pinned down from documentation alone.
# This is the best-documented pattern (Redshift's native event-notification
# system is exposed to EventBridge under source "aws.redshift"); TREAT THIS
# RULE AS UNVERIFIED until a real event is captured from an active
# integration (e.g. via a temporary catch-all rule with no detail-type filter
# and a CloudWatch Logs target, or the EventBridge console's "sample event"
# / actual delivered event) and this pattern is corrected to match. See
# README "Known follow-ups".
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "integration_state" {
  name        = "${var.name_prefix}-integration-state"
  description = "Zero-ETL integration state-change events (WARNING/ERROR severities) — pattern unverified, see README."

  event_pattern = jsonencode({
    source      = ["aws.redshift"]
    detail-type = ["Redshift Integration Event"]
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
