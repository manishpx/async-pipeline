data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name = "csv-pipeline-${var.env}"
}

# ---------- KMS ----------
resource "aws_kms_key" "pipeline" {
  description             = "CMK for CSV pipeline (S3, RDS, DDB, Secrets, Logs)"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })
}

resource "aws_kms_alias" "pipeline" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.pipeline.key_id
}

# ---------- S3 ----------
resource "aws_s3_bucket" "uploads" {
  bucket        = "${local.name}-uploads-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # flip to false for prod
}

resource "aws_s3_bucket" "processed" {
  bucket        = "${local.name}-processed-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "processed" {
  bucket                  = aws_s3_bucket.processed.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration { status = "Enabled" } # required for CRR
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.pipeline.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.pipeline.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    id     = "expire-raw-pii"
    status = "Enabled"
    expiration { days = 1 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id
  rule {
    id     = "expire-intermediates"
    status = "Enabled"
    expiration { days = 7 }
  }
}

resource "aws_s3_bucket_notification" "uploads" {
  bucket      = aws_s3_bucket.uploads.id
  eventbridge = true
}

resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  cors_rule {
    allowed_methods = ["PUT", "POST", "GET"]
    allowed_origins = ["*"] # tighten in prod
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_policy" "uploads_tls" {
  bucket = aws_s3_bucket.uploads.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.uploads.arn, "${aws_s3_bucket.uploads.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ---------- DynamoDB ----------
resource "aws_dynamodb_table" "jobs" {
  name         = "${local.name}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "jobId"

  attribute {
    name = "jobId"
    type = "S"
  }

  point_in_time_recovery { enabled = true }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.pipeline.arn
  }
}

# ---------- SNS ----------
resource "aws_sns_topic" "user_notify" {
  name              = "${local.name}-user-notify"
  kms_master_key_id = aws_kms_key.pipeline.id
}

resource "aws_sns_topic" "ops_alerts" {
  name              = "${local.name}-ops-alerts"
  kms_master_key_id = aws_kms_key.pipeline.id
}

resource "aws_sns_topic_subscription" "ops_email" {
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = var.notify_email
}

# ---------- Secrets ----------
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name       = "${local.name}/db"
  kms_key_id = aws_kms_key.pipeline.arn
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
  })
}

resource "aws_secretsmanager_secret" "enrich_api" {
  name       = "${local.name}/enrich-api"
  kms_key_id = aws_kms_key.pipeline.arn
}

resource "aws_secretsmanager_secret_version" "enrich_api" {
  secret_id     = aws_secretsmanager_secret.enrich_api.id
  secret_string = jsonencode({ api_key = "REPLACE_ME" })
  lifecycle { ignore_changes = [secret_string] }
}