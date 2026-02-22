variable "prefix" {
  description = "Resource name prefix"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the Batch security group"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for Batch EC2 instances"
  type        = list(string)
}

variable "ecr_repository_url" {
  description = "ECR repository URL for the OpenEvolve Docker image"
  type        = string
}

variable "batch_service_role_arn" {
  description = "ARN of the Batch service role"
  type        = string
}

variable "batch_instance_profile_arn" {
  description = "ARN of the EC2 instance profile for Batch compute environments"
  type        = string
}

variable "batch_job_role_arn" {
  description = "ARN of the IAM role assumed by the container at runtime"
  type        = string
}

variable "spot_fleet_role_arn" {
  description = "ARN of the Spot Fleet IAM role"
  type        = string
}

variable "ecs_execution_role_arn" {
  description = "ARN of the ECS task execution role (required when using secrets in container_properties)"
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group name for container logs"
  type        = string
}

variable "gemini_secret_arn" {
  description = "Secrets Manager ARN for the Gemini API key"
  type        = string
}

variable "input_bucket_name" {
  description = "S3 input bucket name (passed to container as env var)"
  type        = string
}

variable "output_bucket_name" {
  description = "S3 output bucket name (passed to container as env var)"
  type        = string
}

variable "max_vcpus" {
  description = "Maximum vCPUs for each compute environment"
  type        = number
  default     = 256
}

variable "instance_types" {
  description = "EC2 instance types for Batch compute environments"
  type        = list(string)
}
