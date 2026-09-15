# ---------------------------------------------------------------------------
# ECS task execution role: pull the PgBouncer image from ECR, read the two
# DB-credential secrets (injected via the task definition's `secrets` block
# so neither password is ever in plain task-def config), write CloudWatch Logs.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pgbouncer_task_execution" {
  name               = "${var.name_prefix}-pgbouncer-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "pgbouncer_task_execution" {
  role       = aws_iam_role.pgbouncer_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "pgbouncer_task_execution" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      aws_secretsmanager_secret.mv_refresh_db.arn,
      aws_secretsmanager_secret.adhoc_db.arn,
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.poc1.arn]
  }
}

resource "aws_iam_role_policy" "pgbouncer_task_execution" {
  name   = "${var.name_prefix}-pgbouncer-task-execution"
  role   = aws_iam_role.pgbouncer_task_execution.id
  policy = data.aws_iam_policy_document.pgbouncer_task_execution.json
}

# The task role (as opposed to the execution role above) is what the
# containerised application itself would assume — PgBouncer needs none of its
# own AWS API access beyond what ECS Exec requires (see enable_execute_command
# in pgbouncer.tf), so this stays otherwise minimal on purpose.
resource "aws_iam_role" "pgbouncer_task" {
  name               = "${var.name_prefix}-pgbouncer-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "pgbouncer_task_ecs_exec" {
  statement {
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "pgbouncer_task_ecs_exec" {
  name   = "${var.name_prefix}-pgbouncer-task-ecs-exec"
  role   = aws_iam_role.pgbouncer_task.id
  policy = data.aws_iam_policy_document.pgbouncer_task_ecs_exec.json
}

# ---------------------------------------------------------------------------
# Redshift external-schema IAM role. Referenced by IAM_ROLE in the manual
# CREATE EXTERNAL SCHEMA step (sql/02_external_schema.sql) and attached to the
# Redshift Serverless namespace in redshift.tf.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "redshift_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["redshift.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "redshift_federated_query" {
  name               = "${var.name_prefix}-redshift-federated-query"
  assume_role_policy = data.aws_iam_policy_document.redshift_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "redshift_federated_query" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      aws_secretsmanager_secret.mv_refresh_db.arn,
      aws_secretsmanager_secret.adhoc_db.arn,
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.poc1.arn]
  }
}

resource "aws_iam_role_policy" "redshift_federated_query" {
  name   = "${var.name_prefix}-redshift-federated-query"
  role   = aws_iam_role.redshift_federated_query.id
  policy = data.aws_iam_policy_document.redshift_federated_query.json
}
