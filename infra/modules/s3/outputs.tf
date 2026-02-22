output "input_bucket_name" {
  value = aws_s3_bucket.inputs.bucket
}

output "input_bucket_arn" {
  value = aws_s3_bucket.inputs.arn
}

output "output_bucket_name" {
  value = aws_s3_bucket.outputs.bucket
}

output "output_bucket_arn" {
  value = aws_s3_bucket.outputs.arn
}
