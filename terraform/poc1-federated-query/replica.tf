# Read-only lookup of the existing source instance — never modified by this
# module. Used only to source the read replica from its ARN and to pick a
# matching parameter-group family, without hand-constructing either.
data "aws_db_instance" "source" {
  db_instance_identifier = var.source_db_instance_identifier
}

locals {
  # e.g. "16.13" -> "postgres16"
  db_parameter_group_family = "postgres${split(".", data.aws_db_instance.source.engine_version)[0]}"
}

resource "aws_db_subnet_group" "analytics_replica" {
  name       = "${var.name_prefix}-replica"
  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-replica" })
}

resource "aws_security_group" "replica" {
  name        = "${var.name_prefix}-replica"
  description = "Analytics read replica. Ingress from PgBouncer only — the Redshift external schema never talks to this instance directly."
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from PgBouncer"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.pgbouncer.id]
  }

  egress {
    description = "Replication stream back to the source instance over the existing VPC peering route, plus AWS service VPC endpoints"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-replica" })
}

# Enforces the SOW's statement_timeout / idle_in_transaction_session_timeout
# at the instance level, applying to both read-only logins uniformly. Use a
# per-role ALTER ROLE ... SET (see sql/01_read_only_roles.sql) if the two
# logins ever need different values.
resource "aws_db_parameter_group" "analytics_replica" {
  name        = "${var.name_prefix}-replica"
  family      = local.db_parameter_group_family
  description = "Query guardrails for the POC1 analytics read replica."

  parameter {
    name         = "statement_timeout"
    value        = tostring(var.statement_timeout_ms)
    apply_method = "immediate"
  }

  parameter {
    name         = "idle_in_transaction_session_timeout"
    value        = tostring(var.idle_in_transaction_session_timeout_ms)
    apply_method = "immediate"
  }

  tags = var.tags
}

# NOTE: this replicates the ENTIRE source instance (every database on
# postgreslt, not just var.source_db_name) — native RDS read replicas use
# instance-level physical/streaming replication, which has no per-database
# scoping. Unlike POC2's DMS table_mappings (logical replication, selectable
# per schema/table), there is no way to replicate only the in-scope database
# here. var.replica_allocated_storage must therefore cover the source
# instance's full storage usage, not just the in-scope database's share.
resource "aws_db_instance" "analytics_replica" {
  identifier          = "${var.name_prefix}-analytics-replica"
  replicate_source_db = data.aws_db_instance.source.db_instance_arn

  instance_class    = var.replica_instance_class
  allocated_storage = var.replica_allocated_storage
  storage_type      = var.replica_storage_type
  storage_encrypted = true
  kms_key_id        = aws_kms_key.poc1.arn

  db_subnet_group_name   = aws_db_subnet_group.analytics_replica.name
  vpc_security_group_ids = [aws_security_group.replica.id]
  parameter_group_name   = aws_db_parameter_group.analytics_replica.name

  multi_az                   = false
  publicly_accessible        = false
  auto_minor_version_upgrade = false
  copy_tags_to_snapshot      = true
  skip_final_snapshot        = true
  deletion_protection        = false

  tags = merge(var.tags, { Name = "${var.name_prefix}-analytics-replica" })
}
