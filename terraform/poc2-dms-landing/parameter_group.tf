locals {
  # e.g. "15.4" -> "postgres15"
  db_parameter_group_family = "postgres${split(".", var.source_db_engine_version)[0]}"
}


# NOTE: `description` below is intentionally left exactly as originally
# applied. aws_db_parameter_group's description is force-new (RDS's API has
# no ModifyDBParameterGroup field for it — only CreateDBParameterGroup
# accepts one), so editing that string would make Terraform destroy and
# recreate this group. AWS refuses to delete a parameter group while it's
# attached to an instance, so that destroy would fail outright against the
# live, already-attached postgreslt instance — confirmed via a real `plan`
# showing "# forces replacement" the first time this comment's context was
# (wrongly) added to the description field instead of here.
#
# This group is now also what POC3's zero-ETL integration
# (terraform/poc3-zeroetl) requires — see the parameter blocks below for
# rds.replica_identity_full, session_replication_role and
# max_slot_wal_keep_size. It's the ONLY parameter group ever attached to
# postgreslt: POC3 deliberately doesn't create its own, so POC2's DMS CDC and
# POC3's Zero-ETL can synchronise concurrently for the SOW's final comparison
# (deliverable D11) rather than needing separate, mutually exclusive attach
# windows.
resource "aws_db_parameter_group" "logical_replication" {
  name        = "${var.name_prefix}-logical-replication"
  family      = local.db_parameter_group_family
  description = "Enables logical replication for AWS DMS CDC against the POC2 source instance."

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # Required for DMS's capture_ddls setting on the source endpoint (dms.tf) —
  # DMS's DDL-capture support for PostgreSQL sources needs the pglogical
  # extension preloaded. Current live value (confirmed via
  # describe-db-parameters, Source: system) is "pg_stat_statements,pg_tle" —
  # appending, not replacing, since this is the only parameter group attached
  # to postgreslt and those two are presumably relied on elsewhere on the
  # shared instance. Static parameter: needs a reboot to take effect, same as
  # rds.logical_replication above.
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements,pg_tle,pglogical"
    apply_method = "pending-reboot"
  }

  # Required by POC3's zero-ETL integration (AWS RDS User Guide, "Getting
  # started with Amazon RDS zero-ETL integrations" — RDS for PostgreSQL
  # section). Instance-wide, not per-table or per-database: increases WAL
  # volume for all ~28 databases on postgreslt, including POC2's own CDC
  # traffic — watch TransactionLogsDiskUsage/ReplicationSlotDiskUsage after
  # this is applied (monitoring.tf already alarms on both).
  parameter {
    name         = "rds.replica_identity_full"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # Also required for zero-ETL. This is Postgres's own default value, so it's
  # a no-op for POC2's DMS CDC — added explicitly (immediate, no reboot
  # needed) so it can't be silently overridden by a stricter setting later.
  parameter {
    name         = "session_replication_role"
    value        = "origin"
    apply_method = "immediate"
  }

  # AWS's recommended value for zero-ETL sources — prevents the
  # integration's replication slot from being invalidated if WAL
  # accumulates while it briefly isn't consuming (e.g. during creation).
  # -1 (unlimited) is also Postgres's own engine default, so again a no-op
  # for POC2.
  parameter {
    name         = "max_slot_wal_keep_size"
    value        = "-1"
    apply_method = "immediate"
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
