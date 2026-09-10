data "aws_caller_identity" "current" {}

resource "aws_kms_key" "poc2" {
  description             = "${var.name_prefix} customer-managed key for DMS landing zone (S3 + Secrets Manager)"
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
        Sid    = "AllowDmsServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "dms.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          # Needed by AWSServiceRoleForDMSServerless to provision the
          # underlying (internal, DMS-managed) replication instance's
          # encrypted storage — without this, CreateReplicationInstance
          # fails with KMSKeyNotAccessibleFault.
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
        # Lake Formation reads data on a governed principal's behalf via its
        # own service-linked role's temporary, vended credentials — not the
        # principal's own IAM identity. That role needs its own KMS grant
        # here, same pattern as AllowDmsServerlessServiceLinkedRole above
        # (confirmed via a real query failure: "AWSServiceRoleForLakeFormationDataAccess
        # ... not authorized to perform: kms:Decrypt").
        Sid    = "AllowLakeFormationServiceLinkedRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/lakeformation.amazonaws.com/AWSServiceRoleForLakeFormationDataAccess"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowSecretsManagerServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "secretsmanager.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AllowSnsServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        # DMS Serverless provisions its internal replication instance via the
        # AWSServiceRoleForDMSServerless service-linked role, which calls KMS
        # as a real, nameable IAM role (visible in CloudTrail as
        # assumed-role/AWSServiceRoleForDMSServerless) — not as an opaque
        # "Service: dms.amazonaws.com" caller. KMS only matches a "Service"
        # principal for genuinely opaque AWS-internal calls, so that
        # statement above does NOT cover this role; it must be trusted here
        # by its exact ARN instead. This role's own AWS-managed identity
        # policy doesn't grant KMS actions, so without this the underlying
        # CreateReplicationInstance call fails with AccessDenied.
        Sid    = "AllowDmsServerlessServiceLinkedRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/dms.amazonaws.com/AWSServiceRoleForDMSServerless"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
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

resource "aws_kms_alias" "poc2" {
  name          = "alias/${var.name_prefix}-landing"
  target_key_id = aws_kms_key.poc2.key_id
}
