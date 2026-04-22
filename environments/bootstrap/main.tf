# ============================================================
# Bootstrap — S3 state bucket + DynamoDB lock table
#
# This is a standalone Terraform root that is run ONCE before
# the main environments/prod configuration. It provisions the
# S3 bucket and DynamoDB table that prod uses as its remote
# backend, plus a dedicated KMS key to encrypt them.
#
# Because this root has its own persistent local state it is
# completely independent of the prod root — terraform destroy
# in prod will never touch these resources.
#
# The state file is stored outside the project directory so
# it survives git operations, directory changes, and accidental
# deletion of the project folder.
#
# Usage (first time):
#   cd environments/bootstrap
#   terraform init
#   terraform apply
#
# After apply, copy the bucket_name output into the backend
# block of environments/prod/main.tf and run terraform init.
# ============================================================

terraform {
  required_version = ">= 1.3"

  # ============================================================
  # Persistent local backend
  # Stores bootstrap state in the home directory so it is never
  # lost between sessions, git cleans, or directory moves.
  # This is what prevents the KMS alias AlreadyExists error —
  # Terraform always knows what bootstrap has already created.
  # ============================================================
  backend "local" {
    path = "/home/rhel-admin/.terraform-bootstrap/rke2-prod.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.32"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.cluster_name
      ManagedBy   = "terraform"
      Environment = var.environment
      Purpose     = "bootstrap"
    }
  }
}

variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "Name of the RKE2 cluster — used to name bootstrap resources"
  type        = string
  default     = "rke2-prod"
}

variable "environment" {
  description = "Environment label"
  type        = string
  default     = "prod"
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.cluster_name}-tfstate-${data.aws_caller_identity.current.account_id}"
  lock_table  = "${var.cluster_name}-tfstate-lock"
}

# ============================================================
# KMS Key — dedicated to state bucket encryption
# Separate from the EBS KMS key in the prod root so that the
# state bucket can be encrypted independently of the cluster.
# ============================================================
resource "aws_kms_key" "state" {
  description             = "KMS key for RKE2 Terraform state bucket encryption (${var.cluster_name})"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowKeyAdministration"
        Effect    = "Allow"
        Principal = { AWS = data.aws_caller_identity.current.arn }
        Action = [
          "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*",
          "kms:Put*", "kms:Update*", "kms:Revoke*", "kms:Disable*",
          "kms:Get*", "kms:Delete*", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${var.cluster_name}-tfstate-kms-key"
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.cluster_name}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

# ============================================================
# S3 Bucket — Terraform remote state
# ============================================================
resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = local.bucket_name
    Purpose = "terraform-state"
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

# ============================================================
# DynamoDB Table — Terraform state locking
# ============================================================
resource "aws_dynamodb_table" "tfstate_lock" {
  name         = local.lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }

  tags = {
    Name    = local.lock_table
    Purpose = "terraform-state-lock"
  }
}

# ============================================================
# Outputs — copy these into environments/prod/main.tf backend
# ============================================================
output "bucket_name" {
  description = "S3 bucket name — use as 'bucket' in the prod backend block"
  value       = aws_s3_bucket.tfstate.bucket
}

output "dynamodb_table_name" {
  description = "DynamoDB table name — use as 'dynamodb_table' in the prod backend block"
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "kms_key_arn" {
  description = "KMS key ARN — use as 'kms_key_id' in the prod backend block"
  value       = aws_kms_key.state.arn
}

output "aws_region" {
  description = "Region the bootstrap resources were created in"
  value       = var.aws_region
}
