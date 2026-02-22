output "log_group_name" {
  value = aws_cloudwatch_log_group.batch.name
}

output "log_group_arn" {
  value = aws_cloudwatch_log_group.batch.arn
}

output "alert_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
