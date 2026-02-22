output "batch_service_role_arn" {
  value = aws_iam_role.batch_service.arn
}

output "batch_instance_profile_arn" {
  value = aws_iam_instance_profile.batch_instance.arn
}

output "batch_job_role_arn" {
  value = aws_iam_role.batch_job.arn
}

output "spot_fleet_role_arn" {
  value = aws_iam_role.spot_fleet.arn
}

output "ecs_execution_role_arn" {
  value = aws_iam_role.ecs_execution.arn
}
