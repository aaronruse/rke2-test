# ============================================================
# SSH Key Pair
# Read public key from local file path specified in variables.
# The corresponding private key is used to SSH into the bastion,
# and from there to control plane / worker nodes (SSH agent forwarding).
#
# key_name_prefix + lifecycle replacement ensures a new key pair is always
# registered in AWS when the public key content changes (e.g. after
# regenerating your SSH key). This prevents the "Permission denied (publickey)"
# issue caused by stale key pairs surviving a terraform destroy/apply.
# ============================================================

# Read the public key from disk
data "local_file" "ssh_public_key" {
  filename = pathexpand(var.ssh_public_key_path)
}

# Hash the public key content so Terraform detects any change to it
locals {
  ssh_public_key_hash = sha256(trimspace(data.local_file.ssh_public_key.content))
}

resource "aws_key_pair" "rke2" {
  # key_name_prefix lets AWS generate a unique name, allowing create_before_destroy
  # to work — Terraform can register the new pair before deleting the old one.
  key_name_prefix = "${var.cluster_name}-keypair-"
  public_key      = trimspace(data.local_file.ssh_public_key.content)

  tags = merge(var.tags, {
    Name    = "${var.cluster_name}-keypair"
    # Embedding the key hash as a tag forces Terraform to detect key rotation
    # and replace this resource automatically on the next apply.
    KeyHash = local.ssh_public_key_hash
  })

  lifecycle {
    # Recreate the key pair whenever the public key content changes.
    # create_before_destroy ensures the new pair exists in AWS before the
    # old one is removed, so dependent resources (bastion, CP, workers)
    # are never left referencing a deleted key pair.
    create_before_destroy = true
  }
}
