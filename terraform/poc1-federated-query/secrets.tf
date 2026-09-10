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
}
