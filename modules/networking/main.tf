# ============================================================
# VPC
# ============================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vpc"
  })
}

# ============================================================
# Internet Gateway (for bastion + NLB public EIP)
# ============================================================
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-igw"
  })
}

# ============================================================
# Subnets
# ============================================================

# Public subnet — bastion host + worker-facing NLB only
resource "aws_subnet" "bastion" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.bastion_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false # Bastion gets an EIP explicitly; no auto-assign

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-subnet-bastion-public"
    Tier = "public"
  })
}

# Private subnet — control plane nodes
resource "aws_subnet" "control_plane" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.control_plane_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-subnet-control-plane-private"
    Tier = "private"
  })
}

# Private subnet — worker nodes
resource "aws_subnet" "workers" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.worker_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-subnet-workers-private"
    Tier = "private"
  })
}

# ============================================================
# Elastic IP for NAT Gateway (private subnets -> internet)
# ============================================================
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-eip-nat"
  })

  depends_on = [aws_internet_gateway.igw]
}

# ============================================================
# NAT Gateway — in the public/bastion subnet
# Allows control-plane and worker nodes to reach internet
# for package downloads, RKE2 install, etc., without a public IP
# ============================================================
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.bastion.id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-nat-gw"
  })

  depends_on = [aws_internet_gateway.igw]
}

# ============================================================
# Route Tables
# ============================================================

# Public route table — bastion subnet -> IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-rt-public"
  })
}

resource "aws_route_table_association" "bastion_public" {
  subnet_id      = aws_subnet.bastion.id
  route_table_id = aws_route_table.public.id
}

# Private route table — control-plane + workers -> NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-rt-private"
  })
}

resource "aws_route_table_association" "control_plane_private" {
  subnet_id      = aws_subnet.control_plane.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "workers_private" {
  subnet_id      = aws_subnet.workers.id
  route_table_id = aws_route_table.private.id
}

# ============================================================
# Elastic IP for Bastion Host
# ============================================================
resource "aws_eip" "bastion" {
  domain   = "vpc"
  instance = var.bastion_instance_id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-eip-bastion"
  })

  depends_on = [aws_internet_gateway.igw]
}

# ============================================================
# Elastic IPs for Worker-Facing Application NLB
# One EIP per subnet used by the NLB (one AZ here)
# ============================================================
resource "aws_eip" "worker_nlb" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-eip-worker-nlb"
  })

  depends_on = [aws_internet_gateway.igw]
}
