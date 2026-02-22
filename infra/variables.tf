variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g., prod, dev, staging)"
  type        = string
  default     = "prod"
}

variable "max_vcpus" {
  description = "Maximum total vCPUs across all Batch compute environments"
  type        = number
  default     = 256
}

variable "instance_types" {
  description = "EC2 instance types for Batch. Mix of sizes lets Spot fleet find capacity."
  type        = list(string)
  # c5/c5a are compute-optimised; good balance for CPU-bound eval + LLM waits.
  # Include multiple sizes so the Spot fleet has more capacity pools to draw from.
  default = ["c5.2xlarge", "c5.4xlarge", "c5a.2xlarge", "c5a.4xlarge", "m5.2xlarge"]
}

variable "iam_users" {
  description = "Short usernames to create (prefixed with 'openevolve-' internally)"
  type        = list(string)
  default     = []
}

variable "alert_email" {
  description = "Email address for CloudWatch alarms and SNS job notifications"
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly spend threshold in USD; SNS alert fires at 80% (actual) and 100% (forecast)"
  type        = number
  default     = 500
}
