# ============================================================
# SSH Key Pair
# Read public key from local file path specified in variables.
# The corresponding private key is used to SSH into the bastion,
# and from there to control plane / worker nodes (SSH agent forwarding).
# ============================================================

# Read the public key from disk
data "local_file" "ssh_public_key" {
  filename = pathexpand(var.ssh_public_key_path)
}

resource "aws_key_pair" "rke2" {
  key_name   = "${var.cluster_name}-keypair"
  public_key = trimspace(data.local_file.ssh_public_key.content)

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-keypair"
  })
}
