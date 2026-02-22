data "aws_region" "current" {}

# ── Security group for Batch instances ───────────────────────────────────────
# No inbound — Batch instances don't accept connections.
# All outbound allowed so containers can reach: ECR (image pull), Gemini API,
# S3 (via NAT gateway), and CloudWatch.
resource "aws_security_group" "batch" {
  name        = "${var.prefix}-batch-sg"
  description = "OpenEvolve Batch instances - egress only"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound (Gemini API, ECR, S3, CloudWatch via NAT)"
  }

  tags = { Name = "${var.prefix}-batch-sg" }
}

# ── Spot compute environment ──────────────────────────────────────────────────
# Primary — runs ~70-90% cheaper than On-Demand.
# SPOT_CAPACITY_OPTIMIZED picks the pools least likely to be interrupted,
# which matters more than squeezing the last cent when jobs run for hours.
resource "aws_batch_compute_environment" "spot" {
  compute_environment_name = "${var.prefix}-spot"
  type                     = "MANAGED"

  compute_resources {
    type                = "SPOT"
    allocation_strategy = "SPOT_CAPACITY_OPTIMIZED"
    # bid_percentage omitted — AWS manages the bid when using SPOT_CAPACITY_OPTIMIZED
    spot_iam_fleet_role = var.spot_fleet_role_arn

    min_vcpus     = 0
    max_vcpus     = var.max_vcpus
    desired_vcpus = 0

    # Multiple instance types = more Spot capacity pools = fewer interruptions
    instance_type = var.instance_types

    subnets            = var.private_subnet_ids
    security_group_ids = [aws_security_group.batch.id]
    instance_role      = var.batch_instance_profile_arn

    tags = {
      Name    = "${var.prefix}-batch-spot"
      Purpose = "openevolve-evolution"
    }
  }

  service_role = var.batch_service_role_arn

  # Note: on a brand-new account, Batch compute environments occasionally fail
  # with "Role does not exist" due to IAM propagation lag. A second
  # `terraform apply` always fixes it — this is a known AWS quirk.
  lifecycle {
    # Batch compute environments can't be updated in-place for most fields;
    # create the replacement before destroying the original.
    create_before_destroy = true
  }
}

# ── On-Demand compute environment (fallback) ──────────────────────────────────
# Batch drains the Spot queue first; On-Demand only runs when Spot has no capacity.
resource "aws_batch_compute_environment" "ondemand" {
  compute_environment_name = "${var.prefix}-ondemand"
  type                     = "MANAGED"

  compute_resources {
    type                = "EC2"
    allocation_strategy = "BEST_FIT_PROGRESSIVE"

    min_vcpus     = 0
    max_vcpus     = var.max_vcpus
    desired_vcpus = 0

    instance_type = var.instance_types

    subnets            = var.private_subnet_ids
    security_group_ids = [aws_security_group.batch.id]
    instance_role      = var.batch_instance_profile_arn

    tags = {
      Name    = "${var.prefix}-batch-ondemand"
      Purpose = "openevolve-evolution"
    }
  }

  service_role = var.batch_service_role_arn

  lifecycle {
    create_before_destroy = true
  }
}

# ── Job queue ─────────────────────────────────────────────────────────────────
# Spot gets order = 1 (tried first); On-Demand gets order = 2 (fallback).
resource "aws_batch_job_queue" "main" {
  name     = "${var.prefix}-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.spot.arn
  }

  compute_environment_order {
    order               = 2
    compute_environment = aws_batch_compute_environment.ondemand.arn
  }
}

# ── Job definition ────────────────────────────────────────────────────────────
resource "aws_batch_job_definition" "openevolve" {
  name = "${var.prefix}-job"
  type = "container"

  container_properties = jsonencode({
    image = "${var.ecr_repository_url}:latest"

    # c5.2xlarge baseline: 8 vCPUs, 16 GiB RAM.
    # Leave ~2 GiB for the OS and ECS agent; claim 14 GiB for the container.
    # Users can override per-job via containerOverrides when submitting.
    vcpus  = 8
    memory = 14000

    # executionRoleArn: used by the ECS agent to pull the image and inject secrets.
    # jobRoleArn: assumed by the running container for S3/CloudWatch access.
    executionRoleArn = var.ecs_execution_role_arn
    jobRoleArn       = var.batch_job_role_arn

    # Static env vars baked into the definition.
    # Per-job vars (S3_INPUT_PREFIX, ITERATIONS, etc.) are set at submit time.
    environment = [
      { name = "PYTHONUNBUFFERED", value = "1" },
      { name = "LOG_LEVEL", value = "INFO" },
      { name = "INPUT_BUCKET", value = var.input_bucket_name },
      { name = "OUTPUT_BUCKET", value = var.output_bucket_name },
    ]

    # GEMINI_API_KEY is injected from Secrets Manager by the ECS agent at
    # container start — never touches the Batch console or task definition
    # in plaintext.
    secrets = [
      {
        name      = "GEMINI_API_KEY"
        valueFrom = var.gemini_secret_arn
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.log_group_name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "batch"
      }
    }

    mountPoints            = []
    volumes                = []
    readonlyRootFilesystem = false
    privileged             = false
  })

  retry_strategy {
    attempts = 3

    # Retry on Spot interruption — OpenEvolve will resume from its last checkpoint
    evaluate_on_exit {
      on_status_reason = "Host EC2*"
      action           = "RETRY"
    }
    # Retry transient ECR pull failures (common on cold Spot instances)
    evaluate_on_exit {
      on_reason = "CannotPullContainerError*"
      action    = "RETRY"
    }
    # Clean exit → stop retrying, mark as succeeded
    evaluate_on_exit {
      on_exit_code = "0"
      action       = "EXIT"
    }
  }

  timeout {
    # Hard ceiling of 24 h — catches runaway jobs before they generate a surprise bill.
    # Most jobs complete in 1-8 h; adjust via containerOverrides per job if needed.
    attempt_duration_seconds = 86400
  }
}
