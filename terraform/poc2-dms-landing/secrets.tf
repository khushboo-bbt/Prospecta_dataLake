resource "aws_secretsmanager_secret" "source_db" {
  name        = "${var.name_prefix}/source-db-credentials"
  description = "Credentials AWS DMS uses to connect to the source Amazon RDS for PostgreSQL instance."
  kms_key_id  = aws_kms_key.poc2.arn

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "source_db" {
  secret_id = aws_secretsmanager_secret.source_db.id

  secret_string = jsonencode({
    username = var.source_db_username
    password = var.source_db_password
    engine   = "postgres"
    host     = var.source_db_endpoint
    port     = var.source_db_port
    dbname   = var.source_db_name
  })
}
