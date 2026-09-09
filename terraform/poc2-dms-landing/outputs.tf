output "landing_bucket_name" {
  description = "S3 bucket receiving DMS full-load and CDC Parquet output."
  value       = aws_s3_bucket.landing.bucket
}

output "kms_key_arn" {
  description = "Customer-managed KMS key used for the secret and the S3 landing bucket."
  value       = aws_kms_key.poc2.arn
}

output "source_db_secret_arn" {
  description = "Secrets Manager secret ARN holding the DMS source DB credentials."
  value       = aws_secretsmanager_secret.source_db.arn
}

output "parameter_group_name" {
  description = "DB parameter group enabling logical replication. Associate this with the source RDS instance and reboot per the README runbook."
  value       = aws_db_parameter_group.logical_replication.name
}

output "source_endpoint_arn" {
  value = aws_dms_endpoint.source.endpoint_arn
}

output "target_endpoint_arn" {
  value = aws_dms_s3_endpoint.target.endpoint_arn
}

output "replication_config_arn" {
  value = aws_dms_replication_config.poc2.arn
}

output "full_load_only_replication_config_arn" {
  description = "ARN of the temporary full-load-only replication config, if created (create_full_load_only_replication = true)."
  value       = try(aws_dms_replication_config.poc2_full_load_only[0].arn, null)
}

output "dms_cloudwatch_log_group" {
  value = aws_cloudwatch_log_group.dms.name
}
