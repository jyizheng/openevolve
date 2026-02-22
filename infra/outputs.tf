output "ecr_repository_url" {
  description = "ECR repository URL — tag and push images here"
  value       = module.ecr.repository_url
}

output "input_bucket_name" {
  description = "S3 bucket for job inputs (programs, evaluators, configs)"
  value       = module.s3.input_bucket_name
}

output "output_bucket_name" {
  description = "S3 bucket for job outputs (checkpoints, results, artifacts)"
  value       = module.s3.output_bucket_name
}

output "job_queue_name" {
  description = "AWS Batch job queue name"
  value       = module.batch.job_queue_name
}

output "job_definition_name" {
  description = "AWS Batch job definition name (includes revision, e.g. openevolve-prod-job:1)"
  value       = module.batch.job_definition_name
}

output "gemini_secret_arn" {
  description = "Secrets Manager ARN for the Gemini API key — populate this manually after deploy"
  value       = module.secrets.gemini_secret_arn
}

output "log_group_name" {
  description = "CloudWatch log group for all Batch job output"
  value       = module.monitoring.log_group_name
}

output "alert_topic_arn" {
  description = "SNS topic ARN for operational alerts"
  value       = module.monitoring.alert_topic_arn
}

output "user_credentials" {
  description = "IAM access keys for created users (sensitive — use: terraform output -json user_credentials)"
  value       = module.users.user_credentials
  sensitive   = true
}

# Print everything a user needs to configure the openevolve-aws CLI
output "cli_config" {
  description = "Export these env vars to configure the openevolve-aws CLI"
  value = {
    OPENEVOLVE_INPUT_BUCKET   = module.s3.input_bucket_name
    OPENEVOLVE_OUTPUT_BUCKET  = module.s3.output_bucket_name
    OPENEVOLVE_JOB_QUEUE      = module.batch.job_queue_name
    OPENEVOLVE_JOB_DEFINITION = module.batch.job_definition_name
    AWS_DEFAULT_REGION        = var.aws_region
  }
}
