resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  input_bucket_name  = "${var.prefix}-inputs-${random_id.suffix.hex}"
  output_bucket_name = "${var.prefix}-outputs-${random_id.suffix.hex}"
}

# ── Input bucket (initial programs, evaluators, configs) ──────────────────────
resource "aws_s3_bucket" "inputs" {
  bucket = local.input_bucket_name
}

resource "aws_s3_bucket_public_access_block" "inputs" {
  bucket                  = aws_s3_bucket.inputs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "inputs" {
  bucket = aws_s3_bucket.inputs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── Output bucket (checkpoints, results, artifacts) ───────────────────────────
resource "aws_s3_bucket" "outputs" {
  bucket = local.output_bucket_name
}

resource "aws_s3_bucket_public_access_block" "outputs" {
  bucket                  = aws_s3_bucket.outputs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "outputs" {
  bucket = aws_s3_bucket.outputs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "outputs" {
  bucket = aws_s3_bucket.outputs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "outputs" {
  bucket = aws_s3_bucket.outputs.id

  # Move user output data through storage tiers automatically.
  # Checkpoints are the dominant cost driver; final results stay accessible.
  rule {
    id     = "user-data-tiering"
    status = "Enabled"

    filter {
      prefix = "users/"
    }

    # STANDARD_IA requires >= 30 days minimum before transition
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    # Move old checkpoint versions to Glacier after 30 days (keep latest via versioning)
    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER"
    }

    # Hard-delete superseded checkpoint versions after 90 days
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}
