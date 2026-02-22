variable "prefix" {
  description = "Resource name prefix"
  type        = string
}

variable "region" {
  description = "AWS region (needed for Log Insights queries in dashboard)"
  type        = string
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}

variable "alert_email" {
  description = "Email address for operational alerts; empty string disables the subscription"
  type        = string
  default     = ""
}

variable "monthly_budget" {
  description = "Monthly AWS cost budget in USD"
  type        = number
  default     = 500
}
