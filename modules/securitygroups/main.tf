# ============================================================
# Security Group: Bastion Host
# Allows SSH inbound only (restrict source_cidr in production
# to your organization's egress IP / VPN range).
# ============================================================
resource "aws_security_group" "bastion" {
  name        = "${var.cluster_name}-sg-bastion"
  description = "Bastion host: allow SSH inbound from allowed CIDRs only"
  vpc_id      = var.vpc_id

  # SSH from internet — RESTRICT THIS to your org's IP range in production.
  # Replace 0.0.0.0/0 with your egress NAT IP or VPN CIDR.
  ingress {
    description = "SSH from allowed source"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # TODO: restrict to your source IP/CIDR
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-sg-bastion"
  })
}

# ============================================================
# Security Group: Control Plane Nodes
# ============================================================
resource "aws_security_group" "control_plane" {
  name        = "${var.cluster_name}-sg-control-plane"
  description = "RKE2 control plane nodes"
  vpc_id      = var.vpc_id

  # SSH from bastion only
  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # RKE2 supervisor / API server from workers and bastion
  ingress {
    description = "RKE2 API Server (6443) from workers and VPC"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # RKE2 agent join (supervisor endpoint 9345)
  ingress {
    description = "RKE2 supervisor (9345) from VPC"
    from_port   = 9345
    to_port     = 9345
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # etcd (control plane peers — relevant if you scale to 3 servers)
  ingress {
    description = "etcd peer"
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    self        = true
  }

  # Canal/Flannel VXLAN overlay
  ingress {
    description = "Canal VXLAN (UDP 8472) from cluster nodes"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Kubelet metrics
  ingress {
    description = "Kubelet (10250) from VPC"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # NodePort range (if needed from inside VPC)
  ingress {
    description = "NodePort range from VPC"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-sg-control-plane"
  })
}

# ============================================================
# Security Group: Worker Nodes
# ============================================================
resource "aws_security_group" "workers" {
  name        = "${var.cluster_name}-sg-workers"
  description = "RKE2 worker nodes"
  vpc_id      = var.vpc_id

  # SSH from bastion only
  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # Canal/Flannel VXLAN overlay
  ingress {
    description = "Canal VXLAN (UDP 8472) from cluster nodes"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Kubelet
  ingress {
    description = "Kubelet (10250) from VPC"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # NodePort range — from the application NLB and VPC
  ingress {
    description = "NodePort range from VPC and NLB"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # HTTP/HTTPS for ingress controller NodePorts
  ingress {
    description = "HTTP (80) from application NLB"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS (443) from application NLB"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-sg-workers"
  })
}
