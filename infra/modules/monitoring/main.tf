# ── CloudWatch Log Group ──────────────────────────────────────────────────────
# All Batch job stdout/stderr lands here. Retention at 30 days keeps costs low
# while preserving enough history to debug recent jobs.
resource "aws_cloudwatch_log_group" "batch" {
  name              = "/aws/batch/openevolve"
  retention_in_days = 30
}

# ── SNS Topic (alerts and job notifications) ──────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name = "${var.prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── AWS Budget ────────────────────────────────────────────────────────────────
# Reminder: most OpenEvolve spend is Gemini API (billed outside AWS).
# This budget covers the AWS-side costs: Batch/EC2, S3, NAT Gateway, etc.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.prefix}-monthly-aws"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Alert at 80% of actual spend
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }

  # Alert when forecast exceeds 100% of budget
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }
}

# ── CloudWatch Dashboard ──────────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "openevolve" {
  dashboard_name = var.prefix

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: Batch job queue state
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Batch Job Queue"
          region = var.region
          period = 300
          stat   = "Sum"
          view   = "timeSeries"
          metrics = [
            ["AWS/Batch", "PendingJobCount", "JobQueue", "${var.prefix}-queue"],
            ["AWS/Batch", "RunnableJobCount", "JobQueue", "${var.prefix}-queue"],
            ["AWS/Batch", "RunningJobCount", "JobQueue", "${var.prefix}-queue"],
            ["AWS/Batch", "SucceededJobCount", "JobQueue", "${var.prefix}-queue"],
            ["AWS/Batch", "FailedJobCount", "JobQueue", "${var.prefix}-queue"],
          ]
        }
      },
      # Row 1: Best score across all running jobs
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Best Score (custom metric, emitted by jobs)"
          region = var.region
          period = 60
          stat   = "Maximum"
          view   = "timeSeries"
          metrics = [
            ["OpenEvolve", "BestScore"]
          ]
        }
      },
      # Row 2: Log Insights query — recent errors across all jobs
      {
        type   = "log"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          title  = "Recent Errors (all jobs)"
          query  = "SOURCE '/aws/batch/openevolve' | fields @timestamp, @logStream, @message | filter @message like /ERROR|Exception|Traceback/ | sort @timestamp desc | limit 50"
          region = var.region
          view   = "table"
        }
      },
      # Row 3: Log Insights — job completions
      {
        type   = "log"
        x      = 0
        y      = 12
        width  = 24
        height = 6
        properties = {
          title  = "Job Completions"
          query  = "SOURCE '/aws/batch/openevolve' | fields @timestamp, @logStream, @message | filter @message like /Evolution complete|evolution complete|Job complete/ | sort @timestamp desc | limit 50"
          region = var.region
          view   = "table"
        }
      }
    ]
  })
}
