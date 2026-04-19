# ============================================================
# S3 Objects — SSH public key and Terraform outputs snapshot
#
# The S3 bucket and DynamoDB lock table live in the bootstrap
# root (environments/prod/bootstrap/) and are managed there.
# This file only writes objects into the existing bucket.
#
# Two objects are written on every apply:
#   ssh/rke2_id_ed25519.pub  — the SSH public key for auditing
#   outputs/terraform.json   — snapshot of all Terraform outputs
#
# Both are encrypted with the EBS KMS key via the bucket's
# default server-side encryption configuration.
# ============================================================

locals {
  # Bucket name matches what bootstrap creates — must stay in sync
  # with the bucket_name local in environments/prod/bootstrap/main.tf
  tfstate_bucket = "${var.cluster_name}-tfstate-${data.aws_caller_identity.current.account_id}"
}

# Upload the SSH public key used by the cluster
resource "aws_s3_object" "ssh_public_key" {
  bucket  = local.tfstate_bucket
  key     = "ssh/rke2_id_ed25519.pub"
  content = local.ssh_public_key

  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.ebs.arn

  tags = merge(local.tags, {
    Name    = "rke2-ssh-public-key"
    Purpose = "ssh-key"
  })
}

# Upload a JSON snapshot of all Terraform outputs
resource "aws_s3_object" "tf_outputs" {
  bucket = local.tfstate_bucket
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
