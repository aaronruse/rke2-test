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

variable "iam_instance_profile" {
  description = "IAM instance profile name to attach to the bastion (for S3 kubeconfig access)"
  type        = string
  default     = ""
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
      # NOTE: Intentionally no set -euo pipefail here — cloud-init failures in
      # tooling installs must NOT prevent SSH hardening from completing.
      # Each section is independently error-checked below.

      # ---- Harden SSH first — must succeed before anything else ----
      # This runs before any apt installs so a package failure can never
      # prevent SSH from working after instance launch.

      # Disable password auth and root login
      sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
      sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

      # KbdInteractiveAuthentication replaces ChallengeResponseAuthentication
      # in OpenSSH 8.7+ (Ubuntu 24.04 ships 9.6). Set both for compatibility.
      sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
      grep -qxF 'KbdInteractiveAuthentication no' /etc/ssh/sshd_config \
        || echo 'KbdInteractiveAuthentication no' >> /etc/ssh/sshd_config

      # IMPORTANT: Keep UsePAM yes on Ubuntu 24.04 — setting it to no breaks
      # pubkey authentication because Ubuntu's sshd relies on PAM for session
      # setup and account validation even for key-based logins.
      sed -i 's/^#*UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config

      # Ensure SSH agent forwarding is allowed (for jumping to internal nodes)
      grep -qxF 'AllowAgentForwarding yes' /etc/ssh/sshd_config \
        || echo 'AllowAgentForwarding yes' >> /etc/ssh/sshd_config

      # Ubuntu 24.04 uses ssh.service; fall back to sshd for older releases
      systemctl restart ssh || systemctl restart sshd
      echo "SSH hardening complete."

      # ---- Install base tooling (awscli excluded — installed separately below) ----
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq \
        curl wget unzip jq \
        bash-completion \
        python3 python3-pip || echo "WARNING: some apt packages failed to install"

      # ---- Install awscli v2 via official installer (not apt — removed in Ubuntu 24.04) ----
      if ! command -v aws &>/dev/null; then
        curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
        unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2
        /tmp/awscliv2/aws/install
        rm -rf /tmp/awscliv2.zip /tmp/awscliv2
        echo "awscli v2 installed."
      fi

      # ---- Install kubectl matching RKE2 1.26 ----
      KUBECTL_VERSION="v1.26.15"
      curl -sSL "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl \
        && chmod +x /usr/local/bin/kubectl \
        && echo "kubectl $${KUBECTL_VERSION} installed." \
        || echo "WARNING: kubectl install failed"

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
  iam_instance_profile   = var.iam_instance_profile != "" ? var.iam_instance_profile : null

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
