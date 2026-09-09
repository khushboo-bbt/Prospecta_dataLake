resource "aws_dms_endpoint" "source" {
  endpoint_id   = "${var.name_prefix}-source-postgres"
  endpoint_type = "source"
  engine_name   = "postgres"

  # server_name/port are NOT set here — they conflict with
  # secrets_manager_access_role_arn/secrets_manager_arn below. The secret
  # itself already carries host/port/dbname/username/password (secrets.tf).
  database_name = var.source_db_name
  ssl_mode      = var.source_db_ssl_mode

  secrets_manager_access_role_arn = aws_iam_role.dms_secrets_access.arn
  secrets_manager_arn             = aws_secretsmanager_secret.source_db.arn

  tags = var.tags

  depends_on = [aws_iam_role_policy.dms_secrets_access]
}

resource "aws_dms_s3_endpoint" "target" {
  endpoint_id   = "${var.name_prefix}-target-s3"
  endpoint_type = "target"

  bucket_name             = aws_s3_bucket.landing.bucket
  service_access_role_arn = aws_iam_role.dms_s3_target.arn

  data_format                      = "parquet"
  parquet_version                  = "parquet-1-0"
  parquet_timestamp_in_millisecond = true

  date_partition_enabled   = true
  date_partition_sequence  = var.date_partition_sequence
  date_partition_delimiter = "SLASH"

  cdc_max_batch_interval = var.cdc_max_batch_interval_seconds
  cdc_min_file_size      = var.cdc_min_file_size_kb

  encryption_mode                   = "SSE_KMS"
  server_side_encryption_kms_key_id = aws_kms_key.poc2.arn

  add_column_name          = true
  include_op_for_full_load = true
  timestamp_column_name    = "dms_load_timestamp"

  tags = var.tags

  depends_on = [aws_iam_role_policy.dms_s3_target]
}

resource "aws_cloudwatch_log_group" "dms" {
  name              = "/dms/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.poc2.arn

  tags = var.tags
}

resource "aws_dms_replication_config" "poc2" {
  replication_config_identifier = "${var.name_prefix}-full-load-cdc"
  resource_identifier           = "${var.name_prefix}-full-load-cdc"

  source_endpoint_arn = aws_dms_endpoint.source.endpoint_arn
  target_endpoint_arn = aws_dms_s3_endpoint.target.endpoint_arn

  replication_type = "full-load-and-cdc"
  table_mappings   = jsonencode(var.table_mappings)

  compute_config {
    replication_subnet_group_id = aws_dms_replication_subnet_group.poc2.replication_subnet_group_id
    vpc_security_group_ids      = concat([aws_security_group.dms.id], var.dms_security_group_ids)
    min_capacity_units          = var.dms_min_capacity_units
    max_capacity_units          = var.dms_max_capacity_units
    multi_az                    = false
    # Deliberately NOT our custom CMK here — DMS Serverless's internal
    # replication instance provisioning needs a KMS grant from an internal
    # EC2-infrastructure principal that our custom key's policy couldn't
    # satisfy (kept failing with KMSKeyNotAccessibleFault even after
    # granting the AWSServiceRoleForDMSServerless role directly). Omitting
    # this lets DMS use its own default-managed key (alias/aws/dms), which
    # already has the right permissions built in. The custom CMK still
    # encrypts the S3 bucket, Secrets Manager secret, and CloudWatch Logs.
  }

  replication_settings = jsonencode({
    Logging = {
      EnableLogging = true
      LogComponents = [
        { Id = "SOURCE_UNLOAD", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TARGET_LOAD", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "SOURCE_CAPTURE", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TARGET_APPLY", Severity = "LOGGER_SEVERITY_DEFAULT" },
      ]
    }
  })

  start_replication = var.start_replication

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.dms_vpc_role,
    aws_iam_role_policy_attachment.dms_cloudwatch_logs_role,
  ]
}

# S3 target for the full-load-only config below — DMS rejects date
# partitioning on a full-load-only task (it only applies to CDC output), so
# this is identical to aws_dms_s3_endpoint.target except date partitioning
# is off. Writes to the same bucket. The main target endpoint is untouched.
resource "aws_dms_s3_endpoint" "target_full_load_only" {
  count = var.create_full_load_only_replication ? 1 : 0

  endpoint_id   = "${var.name_prefix}-target-s3-full-load-only"
  endpoint_type = "target"

  bucket_name             = aws_s3_bucket.landing.bucket
  service_access_role_arn = aws_iam_role.dms_s3_target.arn

  data_format                      = "parquet"
  parquet_version                  = "parquet-1-0"
  parquet_timestamp_in_millisecond = true

  date_partition_enabled = false

  encryption_mode                   = "SSE_KMS"
  server_side_encryption_kms_key_id = aws_kms_key.poc2.arn

  add_column_name          = true
  include_op_for_full_load = true
  timestamp_column_name    = "dms_load_timestamp"

  tags = merge(var.tags, { Purpose = "Temporary-full-load-only-while-CDC-blocked" })

  depends_on = [aws_iam_role_policy.dms_s3_target]
}

# Temporary, parallel replication config — plain "full-load" (no CDC), which
# does NOT require rds.logical_replication to be enabled on the source.
# Reuses the same source endpoint/subnet group/security group/table_mappings
# as aws_dms_replication_config.poc2 above; that main config is untouched.
# Remove by setting create_full_load_only_replication = false once the main
# full-load-and-cdc config can run instead.
resource "aws_dms_replication_config" "poc2_full_load_only" {
  count = var.create_full_load_only_replication ? 1 : 0

  replication_config_identifier = "${var.name_prefix}-full-load-only"
  resource_identifier           = "${var.name_prefix}-full-load-only"

  source_endpoint_arn = aws_dms_endpoint.source.endpoint_arn
  target_endpoint_arn = aws_dms_s3_endpoint.target_full_load_only[0].endpoint_arn

  replication_type = "full-load"
  table_mappings   = jsonencode(var.table_mappings)

  compute_config {
    replication_subnet_group_id = aws_dms_replication_subnet_group.poc2.replication_subnet_group_id
    vpc_security_group_ids      = concat([aws_security_group.dms.id], var.dms_security_group_ids)
    min_capacity_units          = var.dms_min_capacity_units
    max_capacity_units          = var.dms_max_capacity_units
    multi_az                    = false
  }

  replication_settings = jsonencode({
    Logging = {
      EnableLogging = true
      LogComponents = [
        { Id = "SOURCE_UNLOAD", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TARGET_LOAD", Severity = "LOGGER_SEVERITY_DEFAULT" },
      ]
    }
  })

  start_replication = false

  tags = merge(var.tags, { Purpose = "Temporary-full-load-only-while-CDC-blocked" })

  depends_on = [
    aws_iam_role_policy_attachment.dms_vpc_role,
    aws_iam_role_policy_attachment.dms_cloudwatch_logs_role,
  ]
}
