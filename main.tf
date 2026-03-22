# ============================================================
# SSH public key content (used by rke2-aws-tf modules)
# ============================================================
locals {
  ssh_public_key = trimspace(data.local_file.ssh_public_key.content)

  # RKE2 server configuration
  # ⚠️  169.254.0.0/16 pod CIDR is non-standard (link-local range).
  #    Standard default is 10.42.0.0/16. Honoring your request.
  rke2_server_config = yamlencode({
    # Kubernetes networking
    cluster-cidr       = var.pod_cidr
    service-cidr       = var.service_cidr

    # CoreDNS is the default in RKE2 — explicitly set for clarity
    cluster-dns = cidrhost(var.service_cidr, 10)  # e.g. 10.96.0.10

    # Node-level configuration
    node-label = [
      "node-role.kubernetes.io/control-plane=true"
    ]

    # Disable default nginx ingress on control plane
    # (nginx will run on workers only)
    disable = ["rke2-ingress-nginx"]

    # Security: enforce RBAC & audit logging
    kube-apiserver-arg = [
      "audit-log-path=/var/log/kube-audit/audit.log",
      "audit-log-maxage=30",
      "audit-log-maxbackup=10",
      "audit-log-maxsize=100",
    ]
  })

  # RKE2 agent (worker) configuration
  rke2_agent_config = yamlencode({
    node-label = [
      "node-role.kubernetes.io/worker=true"
    ]
  })

  tags = merge(var.tags, {
    Project     = var.cluster_name
    Environment = var.environment
  })
}

# ============================================================
# Bastion Module (custom — in modules/bastion/)
# ============================================================
module "bastion" {
  source = "./modules/bastion"

  name              = var.cluster_name
  vpc_id            = aws_vpc.main.id
  subnet_id         = aws_subnet.bastion.id
  security_group_id = aws_security_group.bastion.id
  ami_id            = var.ami_id
  instance_type     = var.bastion_instance_type
  key_name          = aws_key_pair.rke2.key_name
  tags              = local.tags
}

# ============================================================
# RKE2 Server (Control Plane) — rancherfederal module
# ============================================================
module "rke2" {
  source = "git::https://github.com/rancherfederal/rke2-aws-tf.git?ref=v2.5.1"

  cluster_name = var.cluster_name
  vpc_id       = aws_vpc.main.id
  subnets      = [aws_subnet.control_plane.id]
  ami          = var.ami_id

  # Instance configuration
  instance_type = var.control_plane_instance_type
  servers       = var.control_plane_count

  # Disk
  block_device_mappings = {
    size      = tostring(var.control_plane_disk_size_gb)
    encrypted = "true"
    type      = "gp3"
  }

  # SSH
  ssh_authorized_keys = [local.ssh_public_key]

  # Keep control plane internal (not publicly accessible) — best practice
  controlplane_internal = true

  # RKE2 version
  rke2_version = var.rke2_version
  rke2_channel = var.rke2_channel

  # RKE2 cluster networking config
  rke2_config = local.rke2_server_config

  # IMDSv2 enforced
  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 3
    instance_metadata_tags      = "disabled"
  }

  # SSH hardening userdata (pre-RKE2)
  pre_userdata = <<-EOF
    #!/bin/bash
    set -euo pipefail
    # Disable password auth and root login
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    systemctl restart ssh || systemctl restart sshd

    # Ubuntu 24.04 + RKE2 1.26 compatibility: ensure cgroup v2 is supported
    # and required kernel modules are loaded
    modprobe overlay
    modprobe br_netfilter
    printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-kubernetes.conf
    net.bridge.bridge-nf-call-iptables  = 1
    net.bridge.bridge-nf-call-ip6tables = 1
    net.ipv4.ip_forward                 = 1
    SYSCTL
    sysctl --system
  EOF

  # Security group additions — allow workers and bastion to communicate with CP
  extra_security_group_ids = [aws_security_group.control_plane.id]

  # ASG termination policy
  termination_policies = ["Default"]

  # Increase timeout for CIS hardened image bootstrap (default is 10m)
  wait_for_capacity_timeout = var.wait_for_capacity_timeout

  tags = local.tags
}

# ============================================================
# RKE2 Agent (Worker) Nodepool — rancherfederal module
# ============================================================
module "rke2_workers" {
  source = "git::https://github.com/rancherfederal/rke2-aws-tf.git//modules/agent-nodepool?ref=v2.5.1"

  name    = "workers"
  vpc_id  = aws_vpc.main.id
  subnets = [aws_subnet.workers.id]
  ami     = var.ami_id

  # Instance configuration
  instance_type = var.worker_instance_type

  # Spot instances — enabled for cost reduction (~60-70% cheaper than On-Demand).
  # AWS may reclaim spot instances with a 2-minute warning. The ASG will
  # automatically replace interrupted nodes; RKE2 will reschedule pods onto
  # the replacement. Ensure your workloads tolerate brief pod restarts.
  # Toggle via var.worker_spot in terraform.tfvars.
  spot = var.worker_spot

  # ASG sizing:
  # - min/desired = worker_count (4) — maintain the target fleet size
  # - max = worker_count + 2 — gives the ASG headroom to launch replacement
  #   nodes before terminating interrupted spot instances, avoiding a gap
  asg = {
    min     = var.worker_count
    max     = var.worker_count + 2
    desired = var.worker_count
  }

  # 350GB root disk
  block_device_mappings = {
    size      = tostring(var.worker_disk_size_gb)
    encrypted = "true"
    type      = "gp3"
  }

  # SSH
  ssh_authorized_keys = [local.ssh_public_key]

  # RKE2 version
  rke2_version = var.rke2_version
  rke2_channel = var.rke2_channel

  # RKE2 agent config
  rke2_config = local.rke2_agent_config

  # IMDSv2 enforced
  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 3
    instance_metadata_tags      = "disabled"
  }

  # SSH hardening userdata (pre-RKE2)
  pre_userdata = <<-EOF
    #!/bin/bash
    set -euo pipefail
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    systemctl restart ssh || systemctl restart sshd

    # Ubuntu 24.04 + RKE2 1.26 compatibility
    modprobe overlay
    modprobe br_netfilter
    printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-kubernetes.conf
    net.bridge.bridge-nf-call-iptables  = 1
    net.bridge.bridge-nf-call-ip6tables = 1
    net.ipv4.ip_forward                 = 1
    SYSCTL
    sysctl --system
  EOF

  # Security group additions — attach worker SG
  extra_security_group_ids = [aws_security_group.workers.id]

  # Join the cluster created by the rke2 module
  cluster_data = module.rke2.cluster_data

  tags = local.tags
}

# ============================================================
# Application Network Load Balancer (Worker-Facing)
# Sits in front of the 4 worker nodes for application traffic.
# Uses an Elastic IP for a stable public address.
# ============================================================
resource "aws_lb" "app" {
  name               = "${var.cluster_name}-app-nlb"
  internal           = false
  load_balancer_type = "network"

  # Use the pre-allocated EIP for a stable public IP
  subnet_mapping {
    subnet_id     = aws_subnet.bastion.id
    allocation_id = aws_eip.worker_nlb.id
  }

  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = false

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-app-nlb"
  })
}

# Target Group — HTTP (80) to worker NodePort for ingress-nginx HTTP
resource "aws_lb_target_group" "http" {
  name        = "${var.cluster_name}-tg-http"
  port        = 80
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 10
  }

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-tg-http"
  })
}

# Target Group — HTTPS (443) to worker NodePort for ingress-nginx HTTPS
resource "aws_lb_target_group" "https" {
  name        = "${var.cluster_name}-tg-https"
  port        = 443
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 10
  }

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-tg-https"
  })
}

# NLB Listener: HTTP port 80 -> worker target group
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http.arn
  }
}

# NLB Listener: HTTPS port 443 -> worker target group
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.https.arn
  }
}

# Attach worker ASG to the NLB target groups
resource "aws_autoscaling_attachment" "workers_http" {
  autoscaling_group_name = module.rke2_workers.nodepool_id
  lb_target_group_arn    = aws_lb_target_group.http.arn
}

resource "aws_autoscaling_attachment" "workers_https" {
  autoscaling_group_name = module.rke2_workers.nodepool_id
  lb_target_group_arn    = aws_lb_target_group.https.arn
}
