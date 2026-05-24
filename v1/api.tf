data "archive_file" "request_upload" {
  type        = "zip"
  source_file = "${path.module}/lambda/request_upload.py"
  output_path = "${path.module}/build/request_upload.zip"
}

data "archive_file" "get_status" {
  type        = "zip"
  source_file = "${path.module}/lambda/get_status.py"
  output_path = "${path.module}/build/get_status.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_request" {
  name               = "${local.name}-lambda-request"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_request_basic" {
  role       = aws_iam_role.lambda_request.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_request" {
  role = aws_iam_role.lambda_request.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.uploads.arn}/uploads/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.pipeline.arn
      }
    ]
  })
}

resource "aws_iam_role" "lambda_status" {
  name               = "${local.name}-lambda-status"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_status_basic" {
  role       = aws_iam_role.lambda_status.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_status" {
  role = aws_iam_role.lambda_status.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem"]
      Resource = aws_dynamodb_table.jobs.arn
    }]
  })
}

resource "aws_lambda_function" "request_upload" {
  function_name    = "${local.name}-request-upload"
  role             = aws_iam_role.lambda_request.arn
  handler          = "request_upload.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.request_upload.output_path
  source_code_hash = data.archive_file.request_upload.output_base64sha256
  timeout          = 10
  environment {
    variables = {
      UPLOADS_BUCKET = aws_s3_bucket.uploads.bucket
      KMS_KEY_ID     = aws_kms_key.pipeline.arn
      REGION         = var.region
    }
  }
}

resource "aws_lambda_function" "get_status" {
  function_name    = "${local.name}-get-status"
  role             = aws_iam_role.lambda_status.arn
  handler          = "get_status.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.get_status.output_path
  source_code_hash = data.archive_file.get_status.output_base64sha256
  timeout          = 5
  environment {
    variables = { JOBS_TABLE = aws_dynamodb_table.jobs.name }
  }
}

resource "aws_apigatewayv2_api" "http" {
  name          = local.name
  protocol_type = "HTTP"
  cors_configuration {
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_origins = ["*"] # tighten in prod
    allow_headers = ["*"]
  }
}

resource "aws_apigatewayv2_integration" "request_upload" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.request_upload.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "get_status" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.get_status.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "request_upload" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /uploads"
  target    = "integrations/${aws_apigatewayv2_integration.request_upload.id}"
}

resource "aws_apigatewayv2_route" "get_status" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "GET /jobs/{jobId}"
  target    = "integrations/${aws_apigatewayv2_integration.get_status.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw_request" {
  statement_id  = "AllowAPIGWInvokeRequest"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.request_upload.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_status" {
  statement_id  = "AllowAPIGWInvokeStatus"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_status.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}