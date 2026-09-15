resource "aws_security_group" "pgbouncer" {
  # name_prefix, not a fixed name: create_before_destroy needs to create the
  # replacement SG while the old one (same name otherwise) still exists -
  # AWS rejects two security groups sharing a name in the same VPC.
  name_prefix = "${var.name_prefix}-pgbouncer-"
  description = "PgBouncer on ECS Fargate, behind the internal NLB."
  vpc_id      = var.vpc_id

  # NOT scoped to aws_security_group.redshift.id: NLB health checks (and, with
  # client-IP preservation, the real proxied traffic too) originate from the
  # load balancer's own node IPs within the VPC, not from an ENI carrying the
  # Redshift security group - a security-group-scoped rule here is silently
  # unreachable by the NLB and the target never becomes healthy. Scoping to
  # the VPC CIDR is what actually works for an NLB target in this account's
  # fully-private, single-VPC design.
  ingress {
    description = "PgBouncer from the internal NLB (health checks + Redshift traffic) within the sandbox VPC"
    from_port   = 6432
    to_port     = 6432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Postgres to the analytics replica, plus AWS service VPC endpoints (443)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Without this, Terraform destroys the old SG before creating the new one
  # and before the ECS service is updated to stop referencing it - the still-
  # running tasks' ENIs are attached to the old SG, so the delete fails with
  # DependencyViolation (this is exactly what happened on the first attempt,
  # after a ~15 minute retry loop). create_before_destroy creates the
  # replacement and lets the ECS service update onto it first.
  lifecycle {
    create_before_destroy = true
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
  # Temporary diagnostic aid - lets `aws ecs execute-command` shell into the
  # running container to check DNS/connectivity to the replica directly,
  # rather than continuing to infer container-internal behavior from outside
  # (CloudWatch logs, NLB health checks). Fine to leave enabled for the rest
  # of the POC; not something that needs to ship to a production design.
  enable_execute_command = true

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

  # NLBs default to cross-zone load balancing OFF. This NLB spans all 3
  # sandbox subnets/AZs, but pgbouncer_desired_count = 2 means at most 2 of
  # those 3 AZs ever have a running task - a client whose connection happens
  # to route through the one AZ's NLB node with no local target gets nothing
  # back and hangs until timeout (confirmed via PgBouncer's own logs showing
  # zero connection attempts ever arriving, despite NLB health checks on the
  # 2 populated AZs passing). Cross-zone balancing lets any AZ's node forward
  # to a target in any other AZ, removing this AZ-affinity dependency.
  enable_cross_zone_load_balancing = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-pgbouncer" })
}

resource "aws_lb_target_group" "pgbouncer" {
  name        = "${var.name_prefix}-pgbouncer"
  port        = 6432
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # Client IP preservation (the default for "ip"-type targets in the same
  # VPC as the NLB) can cause connections to hang rather than fail cleanly
  # when the client and target can end up on the same subnet/path - the
  # target's response gets routed back to the client directly instead of via
  # the NLB, and the client's OS silently drops it since it isn't from the
  # IP it thinks it's talking to. Confirmed via testing: both the bastion and
  # Redshift's federated query hung (not refused) trying to reach PgBouncer
  # through this NLB. Disabling it is the standard fix - we don't do any
  # per-client-IP filtering inside PgBouncer itself (auth is via
  # userlist.txt/password), so there's no downside here.
  preserve_client_ip = false

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
