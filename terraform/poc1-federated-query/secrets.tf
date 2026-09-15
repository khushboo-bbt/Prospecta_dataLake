resource "aws_secretsmanager_secret" "mv_refresh_db" {
  name        = "${var.name_prefix}/mv-refresh-db-credentials"
  description = "Read-only Postgres login used by the Redshift external schema backing the scheduled materialized-view refresh."
  kms_key_id  = aws_kms_key.poc1.arn

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "mv_refresh_db" {
  secret_id = aws_secretsmanager_secret.mv_refresh_db.id

  secret_string = jsonencode({
    username = var.mv_refresh_db_username
    password = var.mv_refresh_db_password
    engine   = "postgres"
    host     = aws_db_instance.analytics_replica.address
    port     = aws_db_instance.analytics_replica.port
    dbname   = var.source_db_name
  })

  # secret_string is intentionally not re-diffed against var.mv_refresh_db_password
  # on every plan: this variable has no default (by design - never hard-coded),
  # so any plan run without the exact original value loaded (a fresh shell
  # without the *.auto.tfvars/TF_VAR in scope, or a placeholder used to preview
  # an unrelated change) would otherwise force-replace this secret version and
  # silently desync it from the actual Postgres role's password. An
  # unrelated apply is not the place to rotate this - a deliberate rotation
  # should remove this ignore temporarily (or use `aws secretsmanager
  # put-secret-value` directly) rather than happen as a side effect.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret" "adhoc_db" {
  name        = "${var.name_prefix}/adhoc-db-credentials"
  description = "Read-only Postgres login used by the Redshift external schema backing ad-hoc analysis."
  kms_key_id  = aws_kms_key.poc1.arn

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "adhoc_db" {
  secret_id = aws_secretsmanager_secret.adhoc_db.id

  secret_string = jsonencode({
    username = var.adhoc_db_username
    password = var.adhoc_db_password
    engine   = "postgres"
    host     = aws_db_instance.analytics_replica.address
    port     = aws_db_instance.analytics_replica.port
    dbname   = var.source_db_name
  })

  # Same reasoning as aws_secretsmanager_secret_version.mv_refresh_db above -
  # var.adhoc_db_password has no default by design, so any plan run without
  # the exact original value loaded would otherwise force-replace this too.
  lifecycle {
    ignore_changes = [secret_string]
  }
}
