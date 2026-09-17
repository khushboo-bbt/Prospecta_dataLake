# aws_rds_integration (not aws_redshift_integration — confirmed via
# `terraform providers schema -json` against this account's pinned provider
# that only aws_rds_integration exposes data_filter, which the SOW's
# table-level filtering requirement needs).
#
# Requires the namespace's resource policy (redshift.tf) to already authorise
# local.source_db_arn — that policy is applied manually, not by Terraform
# (see redshift.tf), so confirm it's set (README) before applying this.
resource "aws_rds_integration" "poc3" {
  integration_name = "${var.name_prefix}-zero-etl"

  source_arn = local.source_db_arn
  target_arn = aws_redshiftserverless_namespace.poc3.arn

  kms_key_id  = aws_kms_key.poc3.arn
  data_filter = var.data_filter

  tags = var.tags
}
