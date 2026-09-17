data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Customer-managed key for the zero-ETL integration, the Redshift Serverless
# namespace, and the poller Lambda's CloudWatch Logs group.
#
# Unlike poc1's key (Decrypt/GenerateDataKey/DescribeKey only), the Redshift
# service principal here also needs kms:CreateGrant — confirmed via the AWS
# RDS User Guide's "Encrypting integrations with a customer managed key"
# sample policy: Redshift creates its own grant on this key when the
# integration is created, it isn't just decrypting with one Bell Blaze grants
# up front.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "poc3" {
  description             = "${var.name_prefix} customer-managed key for the zero-ETL integration, the Redshift Serverless namespace, and the sync-failure poller Lambda's log group."
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountRootFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "AllowRedshiftServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "redshift.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AllowRdsServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AllowCloudWatchLogsServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-kms" })
}

resource "aws_kms_alias" "poc3" {
  name          = "alias/${var.name_prefix}-zero-etl"
  target_key_id = aws_kms_key.poc3.key_id
}
