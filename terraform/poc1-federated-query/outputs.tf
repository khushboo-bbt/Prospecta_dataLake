output "analytics_replica_endpoint" {
  description = "Address of the dedicated analytics read replica. Not used directly by Redshift or Power BI — traffic goes through the PgBouncer NLB instead."
  value       = aws_db_instance.analytics_replica.address
}

output "analytics_replica_arn" {
  value = aws_db_instance.analytics_replica.arn
}

output "pgbouncer_nlb_dns_name" {
  description = "Internal NLB DNS name fronting PgBouncer. Not what the Redshift external schema should use — see pgbouncer_private_dns_name below (Redshift's federated-query resolver can't resolve the raw ELB-assigned hostname, confirmed via testing: curlCode 6, Couldn't resolve host name)."
  value       = aws_lb.pgbouncer.dns_name
}

output "pgbouncer_private_dns_name" {
  description = "Private-hosted-zone hostname for PgBouncer. Point the Redshift external schema (sql/02_external_schema.sql) at THIS host, port 6432 — not pgbouncer_nlb_dns_name."
  value       = aws_route53_record.pgbouncer.name
}

output "pgbouncer_ecr_repository_url" {
  description = "Push the image built from docker/pgbouncer/ here before the ECS service can start."
  value       = aws_ecr_repository.pgbouncer.repository_url
}

output "redshift_workgroup_endpoint" {
  value = aws_redshiftserverless_workgroup.poc1.endpoint
}

output "redshift_namespace_id" {
  value = aws_redshiftserverless_namespace.poc1.namespace_id
}

output "redshift_admin_secret_arn" {
  description = "Secrets Manager secret ARN holding the Redshift-managed admin credential (manage_admin_password = true)."
  value       = aws_redshiftserverless_namespace.poc1.admin_password_secret_arn
}

output "redshift_federated_query_role_arn" {
  description = "IAM role ARN to pass as IAM_ROLE in CREATE EXTERNAL SCHEMA."
  value       = aws_iam_role.redshift_federated_query.arn
}

output "mv_refresh_db_secret_arn" {
  value = aws_secretsmanager_secret.mv_refresh_db.arn
}

output "adhoc_db_secret_arn" {
  value = aws_secretsmanager_secret.adhoc_db.arn
}

output "kms_key_arn" {
  value = aws_kms_key.poc1.arn
}
