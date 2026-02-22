# ── IAM users (one per team member) ──────────────────────────────────────────
resource "aws_iam_user" "users" {
  for_each = toset(var.usernames)
  name     = "${var.prefix}-${each.key}"

  tags = {
    OpenEvolveUser = each.key
  }
}

resource "aws_iam_access_key" "users" {
  for_each = toset(var.usernames)
  user     = aws_iam_user.users[each.key].name
}

# ── Per-user IAM policy ───────────────────────────────────────────────────────
# Each user can only touch their own S3 prefix and submit jobs to the
# shared queue. They can read their own job logs from CloudWatch.
data "aws_iam_policy_document" "user" {
  for_each = toset(var.usernames)

  # S3: List objects under their own prefix only
  statement {
    sid     = "S3ListOwnPrefix"
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      var.input_bucket_arn,
      var.output_bucket_arn,
    ]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["users/${each.key}/*"]
    }
  }

  # S3: Read/write their own objects
  statement {
    sid    = "S3OwnObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${var.input_bucket_arn}/users/${each.key}/*",
      "${var.output_bucket_arn}/users/${each.key}/*",
    ]
  }

  # Batch: Submit jobs to the shared queue using the shared job definition
  statement {
    sid     = "BatchSubmit"
    effect  = "Allow"
    actions = ["batch:SubmitJob"]
    resources = [
      var.job_queue_arn,
      var.job_definition_arn,
      # Also allow versioned job definition ARNs (e.g., arn:...:job-definition/name:*)
      "${var.job_definition_arn}:*",
    ]
  }

  # Batch: Describe and list any job (needed to check status of submitted jobs)
  statement {
    sid     = "BatchRead"
    effect  = "Allow"
    actions = ["batch:DescribeJobs", "batch:ListJobs"]
    resources = ["*"]
  }

  # Batch: Cancel/terminate their own jobs.
  # Note: AWS doesn't support restricting CancelJob to specific job IDs
  # without ABAC (attribute-based access control with job tags).
  # For a trusted internal team this is acceptable. To restrict further,
  # tag jobs with Principal at submit time and add a tag condition here.
  statement {
    sid    = "BatchCancel"
    effect = "Allow"
    actions = [
      "batch:CancelJob",
      "batch:TerminateJob",
    ]
    resources = ["*"]
  }

  # CloudWatch Logs: Read all logs in the shared log group
  statement {
    sid    = "CloudWatchLogsRead"
    effect = "Allow"
    actions = [
      "logs:GetLogEvents",
      "logs:DescribeLogStreams",
      "logs:FilterLogEvents",
      "logs:StartQuery",
      "logs:GetQueryResults",
      "logs:StopQuery",
    ]
    resources = [
      var.log_group_arn,
      "${var.log_group_arn}:*",
    ]
  }

  # Allow the CLI to resolve their own caller identity (used to derive S3 prefix)
  statement {
    sid       = "GetCallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_user_policy" "users" {
  for_each = toset(var.usernames)
  name     = "${var.prefix}-policy"
  user     = aws_iam_user.users[each.key].name
  policy   = data.aws_iam_policy_document.user[each.key].json
}
