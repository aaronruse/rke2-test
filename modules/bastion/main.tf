# ============================================================
# Module: Bastion Host
# A standalone EC2 instance in the public subnet.
# SSH jump host with key-only auth, password auth disabled.
# ============================================================

variable "name" {
  description = "Name prefix"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the bastion (must be a public subnet)"
  type        = string
}

variable "security_group_id" {
  description = "Security group ID for the bastion"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the bastion host"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "AWS key pair name"
  type        = string
}

variable "tags" {
  description = "Tags to apply"
  type        = map(string)
  default     = {}
}

# ============================================================
# Userdata: harden SSH on first boot
# Disables password auth, root login, enforces key-only.
# ============================================================
data "cloudinit_config" "bastion" {
  gzip          = false
  base64_encode = false

  part {
    content_type = "text/x-shellscript"
    content      = <<-EOF
      #!/bin/bash
      set -euo pipefail

      # ---- Harden SSH: disable password auth, root login ----
      sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
      sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
      sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
      sed -i 's/^#*UsePAM.*/UsePAM no/' /etc/ssh/sshd_config

      # Ensure SSH agent forwarding is allowed (for jumping to internal nodes)
      grep -qxF 'AllowAgentForwarding yes' /etc/ssh/sshd_config \
        || echo 'AllowAgentForwarding yes' >> /etc/ssh/sshd_config

      systemctl restart sshd

      # ---- Install useful tooling on the bastion ----
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq \
        curl wget unzip jq awscli \
        bash-completion

      # Install kubectl matching RKE2 1.26
      KUBECTL_VERSION="v1.26.15"
      curl -sSL "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl
      chmod +x /usr/local/bin/kubectl

      echo "Bastion bootstrap complete."
    EOF
  }
}

resource "aws_instance" "bastion" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  key_name               = var.key_name
  vpc_security_group_ids = [var.security_group_id]

  user_data = data.cloudinit_config.bastion.rendered

  # IMDSv2 enforced
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    encrypted             = true
  }

  tags = merge(var.tags, {
    Name = "${var.name}-bastion"
    Role = "bastion"
  })
}

output "instance_id" {
  description = "EC2 instance ID of the bastion"
  value       = aws_instance.bastion.id
}

output "private_ip" {
  description = "Private IP of the bastion (not publicly routable)"
  value       = aws_instance.bastion.private_ip
}
