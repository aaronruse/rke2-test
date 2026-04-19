# ============================================================
# S3 Bucket — Terraform state, SSH public key, and outputs
#
# A single bucket holds three things:
#   state/terraform.tfstate  — Terraform remote state
#   ssh/rke2_id_ed25519.pub  — SSH public key (for reference/auditing)
#   outputs/terraform.json   — Terraform outputs snapshot post-apply
#
# Versioning is enabled so every state file write is retained,
# allowing rollback to any previous state revision.
# The bucket is encrypted with the same KMS key used for EBS.
# Public access is fully blocked.
# ============================================================
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.cluster_name}-tfstate-${data.aws_caller_identity.current.account_id}"

  # Prevent accidental deletion of the bucket while state is inside it.
  # Set to false only when intentionally tearing down the entire environment.
  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.tags, {
    Name    = "${var.cluster_name}-tfstate"
    Purpose = "terraform-state"
  })
}

# Block all public access — state files must never be public
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable versioning so every state write is retained
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt the bucket with the cluster KMS key
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.ebs.arn
    }
    # Enforce KMS encryption — disallow unencrypted uploads
    bucket_key_enabled = true
  }
}

# Enforce TLS-only access to the bucket
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
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# ============================================================
# DynamoDB Table — Terraform state locking
# Prevents concurrent applies from corrupting the state file.
# ============================================================
resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "${var.cluster_name}-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # Encrypt the lock table with the cluster KMS key
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.ebs.arn
  }

  tags = merge(local.tags, {
    Name    = "${var.cluster_name}-tfstate-lock"
    Purpose = "terraform-state-lock"
  })
}

# ============================================================
# S3 Objects — SSH public key and Terraform outputs
#
# These are written after apply so the bucket always holds the
# current SSH key and a snapshot of all Terraform outputs.
# Both objects are encrypted via the bucket's default KMS key.
# ============================================================

# Upload the SSH public key used by the cluster
resource "aws_s3_object" "ssh_public_key" {
  bucket  = aws_s3_bucket.tfstate.id
  key     = "ssh/rke2_id_ed25519.pub"
  content = local.ssh_public_key

  # Object inherits bucket KMS encryption — no extra config needed
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.ebs.arn

  tags = merge(local.tags, {
    Name    = "rke2-ssh-public-key"
    Purpose = "ssh-key"
  })
}

# Upload a JSON snapshot of all Terraform outputs
resource "aws_s3_object" "tf_outputs" {
  bucket = aws_s3_bucket.tfstate.id
  key    = "outputs/terraform.json"

  content = jsonencode({
    bastion_public_ip       = module.networking.bastion_eip_public_ip
    bastion_private_ip      = module.bastion.private_ip
    control_plane_lb_dns    = module.rke2.server_url
    app_nlb_public_ip       = module.networking.worker_nlb_eip_public_ip
    app_nlb_dns             = module.rke2.app_nlb_dns
    kubeconfig_s3_path      = module.rke2.kubeconfig_path
    cluster_name            = module.rke2.cluster_name
    vpc_id                  = module.networking.vpc_id
    control_plane_subnet_id = module.networking.control_plane_subnet_id
    worker_subnet_id        = module.networking.worker_subnet_id
    nat_gateway_public_ip   = module.networking.nat_gateway_public_ip
    ebs_kms_key_arn         = aws_kms_key.ebs.arn
    ebs_kms_key_id          = aws_kms_key.ebs.key_id
    ebs_kms_key_alias       = aws_kms_alias.ebs.name
  })

  content_type           = "application/json"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.ebs.arn

  tags = merge(local.tags, {
    Name    = "terraform-outputs"
    Purpose = "outputs-snapshot"
  })
}
