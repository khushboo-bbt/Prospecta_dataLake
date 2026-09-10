locals {
  # e.g. "15.4" -> "postgres15"
  db_parameter_group_family = "postgres${split(".", var.source_db_engine_version)[0]}"
}

resource "aws_db_parameter_group" "logical_replication" {
  name        = "${var.name_prefix}-logical-replication"
  family      = local.db_parameter_group_family
  description = "Enables logical replication for AWS DMS CDC against the POC2 source instance."

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_replication_slots"
    value        = var.max_replication_slots
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_wal_senders"
    value        = var.max_wal_senders
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "wal_sender_timeout"
    value        = var.wal_sender_timeout
    apply_method = "immediate"
  }

  dynamic "parameter" {
    for_each = var.preserve_idle_in_transaction_session_timeout != null ? [var.preserve_idle_in_transaction_session_timeout] : []
    content {
      name         = "idle_in_transaction_session_timeout"
      value        = parameter.value
      apply_method = "immediate"
    }
  }

  dynamic "parameter" {
    for_each = var.preserve_log_min_duration_statement != null ? [var.preserve_log_min_duration_statement] : []
    content {
      name         = "log_min_duration_statement"
      value        = parameter.value
      apply_method = "immediate"
    }
  }

  dynamic "parameter" {
    for_each = var.preserve_pg_stat_statements_track_planning != null ? [var.preserve_pg_stat_statements_track_planning] : []
    content {
      name         = "pg_stat_statements.track_planning"
      value        = parameter.value
      apply_method = "immediate"
    }
  }

  tags = var.tags
}
