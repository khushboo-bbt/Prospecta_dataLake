resource "aws_security_group" "pgbouncer" {
  name        = "${var.name_prefix}-pgbouncer"
  description = "PgBouncer on ECS Fargate. Ingress from Redshift only, egress to the analytics replica only."
  vpc_id      = var.vpc_id

  ingress {
    description     = "PgBouncer from Redshift Serverless"
    from_port       = 6432
    to_port         = 6432
    protocol        = "tcp"
    security_groups = [aws_security_group.redshift.id]
  }

  egress {
    description = "Postgres to the analytics replica, plus AWS service VPC endpoints (443)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-pgbouncer" })
}

resource "aws_cloudwatch_log_group" "pgbouncer" {
  name              = "/ecs/${var.name_prefix}-pgbouncer"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.poc1.arn

  tags = var.tags
}

resource "aws_ecs_cluster" "pgbouncer" {
  name = "${var.name_prefix}-pgbouncer"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-pgbouncer" })
}

resource "aws_ecs_task_definition" "pgbouncer" {
  family                   = "${var.name_prefix}-pgbouncer"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.pgbouncer_task_cpu
  memory                   = var.pgbouncer_task_memory
  execution_role_arn       = aws_iam_role.pgbouncer_task_execution.arn
  task_role_arn            = aws_iam_role.pgbouncer_task.arn

  container_definitions = jsonencode([
    {
      name      = "pgbouncer"
      image     = "${aws_ecr_repository.pgbouncer.repository_url}:${var.pgbouncer_image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = 6432
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "DB_HOST", value = aws_db_instance.analytics_replica.address },
        { name = "DB_PORT", value = tostring(aws_db_instance.analytics_replica.port) },
        { name = "DB_NAME", value = var.source_db_name },
        { name = "POOL_MODE", value = "transaction" },
        { name = "DEFAULT_POOL_SIZE", value = tostring(var.pgbouncer_pool_size) },
      ]

      # Both read-only logins land in userlist.txt at container start — see
      # docker/pgbouncer/entrypoint.sh. Values come straight from Secrets
      # Manager and are never written into the task definition itself.
      secrets = [
        { name = "MV_REFRESH_DB_USERNAME", valueFrom = "${aws_secretsmanager_secret.mv_refresh_db.arn}:username::" },
        { name = "MV_REFRESH_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.mv_refresh_db.arn}:password::" },
        { name = "ADHOC_DB_USERNAME", valueFrom = "${aws_secretsmanager_secret.adhoc_db.arn}:username::" },
        { name = "ADHOC_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.adhoc_db.arn}:password::" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.pgbouncer.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "pgbouncer"
        }
      }
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "pgbouncer" {
  name            = "${var.name_prefix}-pgbouncer"
  cluster         = aws_ecs_cluster.pgbouncer.id
  task_definition = aws_ecs_task_definition.pgbouncer.arn
  desired_count   = var.pgbouncer_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.pgbouncer.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.pgbouncer.arn
    container_name   = "pgbouncer"
    container_port   = 6432
  }

  depends_on = [aws_lb_listener.pgbouncer]

  tags = var.tags
}

# Internal NLB — this is the endpoint Redshift's external schema is pointed
# at (never the replica directly), so PgBouncer is the only thing that ever
# opens a backend connection to the replica.
resource "aws_lb" "pgbouncer" {
  name               = "${var.name_prefix}-pgbouncer"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-pgbouncer" })
}

resource "aws_lb_target_group" "pgbouncer" {
  name        = "${var.name_prefix}-pgbouncer"
  port        = 6432
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    protocol = "TCP"
    port     = "6432"
  }

  tags = var.tags
}

resource "aws_lb_listener" "pgbouncer" {
  load_balancer_arn = aws_lb.pgbouncer.arn
  port              = 6432
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.pgbouncer.arn
  }
}
