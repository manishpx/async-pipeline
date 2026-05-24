# ---- Frankfurt KMS + bucket for DR ----
resource "aws_kms_key" "dr" {
  provider                = aws.dr
  description             = "DR CMK in Frankfurt for csv-pipeline"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_s3_bucket" "uploads_dr" {
  provider      = aws.dr
  bucket        = "${local.name}-uploads-dr-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "uploads_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.uploads_dr.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.uploads_dr.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.dr.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "uploads_dr" {
  provider                = aws.dr
  bucket                  = aws_s3_bucket.uploads_dr.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---- Replication: uploads -> uploads_dr ----
resource "aws_s3_bucket_replication_configuration" "uploads" {
  depends_on = [aws_s3_bucket_versioning.uploads, aws_s3_bucket_versioning.uploads_dr]
  bucket     = aws_s3_bucket.uploads.id
  role       = aws_iam_role.replication.arn

  rule {
    id     = "dr-frankfurt"
    status = "Enabled"
    filter {}
    delete_marker_replication { status = "Disabled" }
    destination {
      bucket        = aws_s3_bucket.uploads_dr.arn
      storage_class = "STANDARD_IA"
      encryption_configuration {
        replica_kms_key_id = aws_kms_key.dr.arn
      }
    }
    source_selection_criteria {
      sse_kms_encrypted_objects { status = "Enabled" }
    }
  }
}