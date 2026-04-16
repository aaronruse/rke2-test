# ============================================================
# Module: Bastion Host
# A standalone EC2 instance in the public subnet.
# SSH jump host with key-only auth, password auth disabled.
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

      # ---- Install kubectl matching the deployed RKE2 Kubernetes version ----
      # kubectl_version is derived from rke2_version in the env layer and passed
      # into this module, so it always stays in sync with the cluster.
      KUBECTL_VERSION="${var.kubectl_version}"
      curl -sSL "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl \
        && chmod +x /usr/local/bin/kubectl \
        && echo "kubectl $${KUBECTL_VERSION} installed." \
        || echo "WARNING: kubectl install failed"

      # ---- Install uv and Ansible (via uv tool) ----
      # uv is installed as the ubuntu user so tools land in ~/.local/bin
      # and are available on the PATH for interactive SSH sessions.
      if ! sudo -u ubuntu bash -c 'command -v uv &>/dev/null'; then
        sudo -u ubuntu bash -c '
          curl -LsSf https://astral.sh/uv/install.sh | sh
        ' && echo "uv installed." || echo "WARNING: uv install failed"
      fi

      # Install Ansible with kubernetes + openshift extras via uv tool.
      # --with-executables-from ansible-core ensures ansible, ansible-playbook, etc.
      # are placed on the PATH as top-level executables.
      sudo -u ubuntu bash -c '
        export PATH="$HOME/.local/bin:$PATH"
        uv tool install \
          --with-executables-from ansible-core \
          --with kubernetes \
          --with openshift \
          ansible
      ' && echo "Ansible installed via uv." || echo "WARNING: Ansible install via uv failed"

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
