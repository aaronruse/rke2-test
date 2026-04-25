# ============================================================
# S3 Objects — SSH keys, kubeconfig, and Terraform outputs
#
# The S3 bucket itself lives in environments/bootstrap/main.tf
# and is managed there. This file only writes objects into
# the existing bucket. The bucket name is defined as
# local.tfstate_bucket in main.tf.
#
# Objects stored:
#   ssh/rke2_id_ed25519.pub   — SSH public key
#   ssh/rke2_id_ed25519       — SSH private key
#   kubeconfig/config         — Cluster kubeconfig (copied from
#                               the rke2 module's S3 path)
#   outputs/terraform.json    — Snapshot of all Terraform outputs
#
# All objects are encrypted at rest using the bootstrap bucket's
# default KMS key (alias/rke2-prod-tfstate), which is managed
# in environments/bootstrap/main.tf.
# ============================================================

locals {
  # Derive private key path from the public key path variable by
  # stripping the .pub suffix
  ssh_private_key_path = replace(pathexpand(var.ssh_public_key_path), ".pub", "")
}

# Read the private key from disk
data "local_sensitive_file" "ssh_private_key" {
  filename = local.ssh_private_key_path
}

# Upload the SSH public key
resource "aws_s3_object" "ssh_public_key" {
  bucket  = local.tfstate_bucket
  key     = "ssh/rke2_id_ed25519.pub"
  content = local.ssh_public_key

  # Encrypted by the bucket's default KMS key (bootstrap tfstate key)
  server_side_encryption = "aws:kms"

  tags = merge(local.tags, {
    Name    = "rke2-ssh-public-key"
    Purpose = "ssh-key"
  })
}

# Upload the SSH private key
resource "aws_s3_object" "ssh_private_key" {
  bucket  = local.tfstate_bucket
  key     = "ssh/rke2_id_ed25519"
  content = data.local_sensitive_file.ssh_private_key.content

  # Encrypted by the bucket's default KMS key (bootstrap tfstate key)
  server_side_encryption = "aws:kms"

  # Explicitly mark sensitive — prevents content appearing in plan output
  lifecycle {
    ignore_changes = [content]
  }

  tags = merge(local.tags, {
    Name    = "rke2-ssh-private-key"
    Purpose = "ssh-key"
  })
}

# Copy the kubeconfig from the rke2 module's S3 path into our bucket.
# The rancherfederal module uploads the kubeconfig to its own bucket
# during cluster bootstrap. We copy it here so all cluster artifacts
# are in one place. Uses local-exec since the file content is not
# available as a Terraform value — it is written by the RKE2 bootstrap
# process after the cluster comes up.
resource "null_resource" "copy_kubeconfig" {
  # Re-run whenever the kubeconfig S3 path changes (i.e. new cluster)
  triggers = {
    kubeconfig_path = module.rke2.kubeconfig_path
    dest_bucket     = local.tfstate_bucket
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws s3 cp ${module.rke2.kubeconfig_path} \
        s3://${local.tfstate_bucket}/kubeconfig/config \
        --sse aws:kms \
        --region ${var.aws_region}
    EOT
  }

  depends_on = [module.rke2]
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
    kubeconfig_s3_path      = "s3://${local.tfstate_bucket}/kubeconfig/config"
    cluster_name            = module.rke2.cluster_name
    vpc_id                  = module.networking.vpc_id
    control_plane_subnet_id = module.networking.control_plane_subnet_id
    worker_subnet_id        = module.networking.worker_subnet_id
    nat_gateway_public_ip   = module.networking.nat_gateway_public_ip
    ssh_public_key_s3_path  = "s3://${local.tfstate_bucket}/ssh/rke2_id_ed25519.pub"
    ssh_private_key_s3_path = "s3://${local.tfstate_bucket}/ssh/rke2_id_ed25519"
  })

  content_type           = "application/json"
  server_side_encryption = "aws:kms"

  tags = merge(local.tags, {
    Name    = "terraform-outputs"
    Purpose = "outputs-snapshot"
  })
}
