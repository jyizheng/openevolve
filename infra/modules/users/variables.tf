variable "prefix" {
  description = "Resource name prefix"
  type        = string
}

variable "usernames" {
  description = "Short usernames to create as IAM users"
  type        = list(string)
  default     = []
}

variable "input_bucket_arn" {
  description = "ARN of the S3 input bucket"
  type        = string
}

variable "output_bucket_arn" {
  description = "ARN of the S3 output bucket"
  type        = string
}

variable "input_bucket_name" {
  description = "Name of the S3 input bucket"
  type        = string
}

variable "output_bucket_name" {
  description = "Name of the S3 output bucket"
  type        = string
}

variable "job_queue_arn" {
  description = "ARN of the Batch job queue"
  type        = string
}

variable "job_definition_arn" {
  description = "ARN of the Batch job definition (unversioned)"
  type        = string
}

variable "log_group_arn" {
  description = "ARN of the CloudWatch log group for Batch jobs"
  type        = string
}
