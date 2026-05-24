resource "aws_cloudwatch_event_rule" "on_upload" {
  name = "${local.name}-on-upload"
  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = { bucket = { name = [aws_s3_bucket.uploads.bucket] } }
  })
}

resource "aws_cloudwatch_event_target" "to_sfn" {
  rule     = aws_cloudwatch_event_rule.on_upload.name
  arn      = aws_sfn_state_machine.pipeline.arn
  role_arn = aws_iam_role.events_to_sfn.arn
}