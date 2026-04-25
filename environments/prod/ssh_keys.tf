# ============================================================
# SSH Key Pair — Bastion Access
#
# Read from a local file on the machine running Terraform.
# This key is used to SSH into the bastion host only.
# The public key is stored in S3 for reference/auditing.
# ============================================================

# Read the bastion public key from disk
data "local_file" "ssh_public_key" {
  filename = pathexpand(var.ssh_public_key_path)
}

locals {
  ssh_public_key_hash = sha256(trimspace(data.local_file.ssh_public_key.content))
  ssh_public_key      = trimspace(data.local_file.ssh_public_key.content)
}

resource "aws_key_pair" "rke2" {
  key_name_prefix = "${var.cluster_name}-bastion-keypair-"
  public_key      = trimspace(data.local_file.ssh_public_key.content)

  tags = merge(local.tags, {
    Name    = "${var.cluster_name}-bastion-keypair"
    Purpose = "bastion-access"
    KeyHash = local.ssh_public_key_hash
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================
# SSH Key Pair — RKE2 Node Access
#
# Generated on the local filesystem via ssh-keygen during apply.
# The private key NEVER enters Terraform state — it exists only
# on the machine that ran the apply. The public key is read from
# disk and registered in AWS EC2 for node access.
#
# Key paths are controlled by var.node_ssh_private_key_path.
# Default: ~/.ssh/rke2_node_id_ed25519
#
# To SSH into nodes after apply:
#   ssh-add ~/.ssh/rke2_node_id_ed25519
#   ssh -A ubuntu@<bastion-ip>     # from your machine
#   ssh ubuntu@<node-private-ip>   # from the bastion
# ============================================================

# Generate the node key on the local filesystem if it doesn't exist.
# local-exec runs on the machine executing Terraform — the private
# key is written to disk only, never to Terraform state.
resource "null_resource" "generate_node_key" {
  triggers = {
    # Re-generate if the key path changes or the key file is deleted
    key_path = pathexpand(var.node_ssh_private_key_path)
  }

  provisioner "local-exec" {
    command = <<-EOT
      KEY_PATH="${pathexpand(var.node_ssh_private_key_path)}"
      if [ ! -f "$KEY_PATH" ]; then
        mkdir -p "$(dirname "$KEY_PATH")"
        ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "rke2-node-access" -q
        echo "Node SSH key generated at: $KEY_PATH"
      else
        echo "Node SSH key already exists at: $KEY_PATH — skipping generation"
      fi
    EOT
  }
}

# Read the generated public key from disk.
# depends_on ensures the key exists before we try to read it.
data "local_file" "node_ssh_public_key" {
  filename   = "${pathexpand(var.node_ssh_private_key_path)}.pub"
  depends_on = [null_resource.generate_node_key]
}

# Register the node public key in AWS EC2
resource "aws_key_pair" "node" {
  key_name_prefix = "${var.cluster_name}-node-keypair-"
  public_key      = trimspace(data.local_file.node_ssh_public_key.content)

  tags = merge(local.tags, {
    Name    = "${var.cluster_name}-node-keypair"
    Purpose = "node-access"
  })

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [null_resource.generate_node_key]
}
