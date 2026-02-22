output "job_queue_arn" {
  value = aws_batch_job_queue.main.arn
}

output "job_queue_name" {
  value = aws_batch_job_queue.main.name
}

output "job_definition_arn" {
  value = aws_batch_job_definition.openevolve.arn
}

output "job_definition_name" {
  # Returns the versioned name, e.g. "openevolve-prod-job:1"
  value = aws_batch_job_definition.openevolve.name
}
