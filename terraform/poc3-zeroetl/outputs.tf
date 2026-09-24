output "integration_arn" {
  value = aws_rds_integration.poc3.arn
}

output "integration_id" {
  description = "Use this in sql/01_create_target_database.sql's FROM INTEGRATION clause."
  value       = aws_rds_integration.poc3.id
}

output "redshift_workgroup_endpoint" {
  value = aws_redshiftserverless_workgroup.poc3.endpoint
}

output "redshift_namespace_arn" {
  value = aws_redshiftserverless_namespace.poc3.arn
}

output "redshift_security_group_id" {
  description = "Feed into terraform/powerbi-gateway's poc3_redshift_security_group_id variable. Note: this SG already allows inbound 5439 from the whole sandbox VPC CIDR (see networking.tf) - this output is only needed for the gateway's own EGRESS rule, not a matching ingress change here."
  value       = aws_security_group.redshift.id
}

output "redshift_admin_secret_arn" {
  description = "Secrets Manager secret ARN holding the Redshift-managed admin credential (manage_admin_password = true)."
  value       = aws_redshiftserverless_namespace.poc3.admin_password_secret_arn
}

output "sns_topic_arn" {
  value = aws_sns_topic.zero_etl_health.arn
}

output "poller_lambda_name" {
  value = aws_lambda_function.zero_etl_poller.function_name
}

output "kms_key_arn" {
  value = aws_kms_key.poc3.arn
}
