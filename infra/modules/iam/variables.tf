variable "prefix" {
  description = "Resource name prefix"
  type        = string
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "input_bucket_arn" {
  description = "ARN of the S3 input bucket"
  type        = string
}

variable "output_bucket_arn" {
  description = "ARN of the S3 output bucket"
  type        = string
}

variable "gemini_secret_arn" {
  description = "ARN of the Gemini API key secret in Secrets Manager"
  type        = string
}

variable "log_group_arn" {
  description = "ARN of the CloudWatch log group for Batch jobs"
  type        = string
}
