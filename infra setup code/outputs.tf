output "api_endpoint" {
  description = "Invoke URL for the HTTP API"
  value       = aws_apigatewayv2_api.http.api_endpoint
}

output "uploads_bucket" {
  value = aws_s3_bucket.uploads.bucket
}

output "uploads_dr_bucket" {
  value = aws_s3_bucket.uploads_dr.bucket
}

output "processed_bucket" {
  value = aws_s3_bucket.processed.bucket
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.pipeline.arn
}

output "rds_endpoint" {
  value = aws_db_instance.main.endpoint
}

output "jobs_table" {
  value = aws_dynamodb_table.jobs.name
}