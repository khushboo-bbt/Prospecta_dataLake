# PgBouncer has no official AWS-provided image, and the sandbox VPC has no
# NAT/internet gateway (see README) — so the image is built from
# docker/pgbouncer/ and pushed here, rather than pulled from Docker Hub.
resource "aws_ecr_repository" "pgbouncer" {
  name                 = "${var.name_prefix}-pgbouncer"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.poc1.arn
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-pgbouncer" })
}

resource "aws_ecr_lifecycle_policy" "pgbouncer" {
  repository = aws_ecr_repository.pgbouncer.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      }
    ]
  })
}
