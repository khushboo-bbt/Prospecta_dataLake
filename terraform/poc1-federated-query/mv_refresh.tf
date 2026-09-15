# ---------------------------------------------------------------------------
# Scheduled refresh of the bi schema's materialized views (sql/03_materialized
# _views.sql). AUTO REFRESH is rejected outright by Redshift for MVs defined
# over federated/external tables ("ERROR: Auto-refresh is not supported for
# materialized views defined on the referenced tables"), confirmed via
# testing - so this is the only way to keep them from going stale.
#
# NOT EventBridge Scheduler's universal target: confirmed via a real apply
# attempt that CreateSchedule rejects it outright ("the api
# batchExecuteStatement is not valid for the service aws-sdk:redshift-data") -
# unlike Glue's StartJobRun (poc2's eventbridge.tf), BatchExecuteStatement
# isn't on Scheduler's supported-actions list at all.
#
# Redshift Data API scheduling instead has its own first-class, AWS-documented
# integration with classic EventBridge Rules (see "Scheduling Amazon Redshift
# Data API operations with Amazon EventBridge" in the Redshift admin guide),
# exposed in this provider as the `redshift_target` block on
# aws_cloudwatch_event_target (confirmed via `terraform providers schema
# -json`). That block only takes one SQL string (ExecuteStatement, not
# BatchExecuteStatement - which is the only Data API operation that accepts
# multiple statements), so this needs one target per MV.
#
# Targets are split 3 per rule, not all 9 under one rule: a real apply with
# all 9 under one rule hung for over an hour before finally surfacing
# "LimitExceededException: The requested resource exceeds the maximum number
# allowed" - EventBridge's targets-per-rule quota (AWS docs say 5; this
# account's actual cutoff landed somewhere past 7, empirically), which the
# AWS provider mistakes for a retryable throttling error and retries ~25
# times with backoff instead of surfacing it immediately. Groups of 3 stay
# safely under that quota regardless of its exact value for this account.
# ---------------------------------------------------------------------------

locals {
  mv_refresh_groups = {
    a = ["change_request_header", "chng_1_487809", "crud_metadata_mdo"]
    b = ["crud_next_mdo_number", "crud_table_mapping", "databasechangelog"]
    c = ["databasechangeloglock", "dyn_1_487809", "mdo_guardrail_properties"]
  }

  mv_refresh_table_group = merge([
    for group, tables in local.mv_refresh_groups : { for t in tables : t => group }
  ]...)
}

data "aws_iam_policy_document" "eventbridge_mv_refresh_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eventbridge_mv_refresh" {
  name               = "${var.name_prefix}-eventbridge-mv-refresh"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_mv_refresh_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "eventbridge_mv_refresh" {
  statement {
    effect    = "Allow"
    actions   = ["redshift-data:ExecuteStatement"]
    resources = [aws_redshiftserverless_workgroup.poc1.arn]
  }

  # The Data API assumes this role's permissions to retrieve the secret
  # itself when secrets_manager_arn is used instead of db_user/temporary
  # credentials.
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_redshiftserverless_namespace.poc1.admin_password_secret_arn]
  }
}

resource "aws_iam_role_policy" "eventbridge_mv_refresh" {
  name   = "${var.name_prefix}-eventbridge-mv-refresh"
  role   = aws_iam_role.eventbridge_mv_refresh.id
  policy = data.aws_iam_policy_document.eventbridge_mv_refresh.json
}

resource "aws_cloudwatch_event_rule" "mv_refresh" {
  for_each = local.mv_refresh_groups

  name                = "${var.name_prefix}-mv-refresh-schedule-${each.key}"
  schedule_expression = var.mv_refresh_schedule
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "mv_refresh" {
  for_each = local.mv_refresh_table_group

  rule      = aws_cloudwatch_event_rule.mv_refresh[each.value].name
  target_id = "${var.name_prefix}-mv-refresh-${each.key}"
  arn       = aws_redshiftserverless_workgroup.poc1.arn
  role_arn  = aws_iam_role.eventbridge_mv_refresh.arn

  redshift_target {
    database            = aws_redshiftserverless_namespace.poc1.db_name
    secrets_manager_arn = aws_redshiftserverless_namespace.poc1.admin_password_secret_arn
    sql                 = "REFRESH MATERIALIZED VIEW bi.${each.key}_mv;"
    statement_name      = "${var.name_prefix}-mv-refresh-${each.key}"
    with_event          = true
  }
}
