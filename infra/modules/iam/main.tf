# ── Batch Service Role ────────────────────────────────────────────────────────
# Allows Batch to provision EC2, manage ECS clusters, and write CloudWatch logs.

resource "aws_iam_role" "batch_service" {
  name = "${var.prefix}-batch-service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "batch.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "batch_service" {
  role       = aws_iam_role.batch_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

# ── EC2 Instance Role ─────────────────────────────────────────────────────────
# Attached to every EC2 instance in the compute environment.
# AmazonEC2ContainerServiceforEC2Role covers: ECS agent comms, ECR image pull,
# CloudWatch Logs agent, and secrets injection into containers.

resource "aws_iam_role" "batch_instance" {
  name = "${var.prefix}-batch-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "batch_instance_ecs" {
  role       = aws_iam_role.batch_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# The ECS agent (running on the EC2 host) reads Secrets Manager to inject
# secrets as container env vars — so this permission lives on the instance role.
resource "aws_iam_role_policy" "batch_instance_secrets" {
  name = "${var.prefix}-instance-secrets"
  role = aws_iam_role.batch_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = var.gemini_secret_arn
    }]
  })
}

resource "aws_iam_instance_profile" "batch_instance" {
  name = "${var.prefix}-batch-instance"
  role = aws_iam_role.batch_instance.name
}

# ── Spot Fleet Role ───────────────────────────────────────────────────────────
resource "aws_iam_role" "spot_fleet" {
  name = "${var.prefix}-spot-fleet"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "spotfleet.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "spot_fleet" {
  role       = aws_iam_role.spot_fleet.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole"
}

# ── Batch Job Role ────────────────────────────────────────────────────────────
# This is the role the *container* assumes at runtime (jobRoleArn).
# Scoped to exactly what OpenEvolve needs: S3 read/write for job data,
# and CloudWatch custom metrics.

resource "aws_iam_role" "batch_job" {
  name = "${var.prefix}-batch-job"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

data "aws_iam_policy_document" "batch_job" {
  # S3: Read job inputs, write job outputs — scoped to the /users/ prefix
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${var.input_bucket_arn}/users/*",
      "${var.output_bucket_arn}/users/*",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.input_bucket_arn, var.output_bucket_arn]
    # Restrict ListBucket to the users/ prefix so jobs can't enumerate other data
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["users/*"]
    }
  }

  # CloudWatch: Emit custom OpenEvolve metrics (best score, iteration count, etc.)
  # Namespace condition prevents containers from polluting arbitrary namespaces.
  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["OpenEvolve"]
    }
  }

  # CloudWatch Logs: Write structured logs to the job log group
  statement {
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "${var.log_group_arn}",
      "${var.log_group_arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "batch_job" {
  name   = "${var.prefix}-job-policy"
  role   = aws_iam_role.batch_job.id
  policy = data.aws_iam_policy_document.batch_job.json
}

# ── ECS Task Execution Role ───────────────────────────────────────────────────
# Required by AWS Batch when using `secrets` in container_properties.
# The ECS agent assumes this role to pull the image from ECR and inject the
# Gemini API key from Secrets Manager before the container starts.
resource "aws_iam_role" "ecs_execution" {
  name = "${var.prefix}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "${var.prefix}-ecs-execution-secrets"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = var.gemini_secret_arn
    }]
  })
}
