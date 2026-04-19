terraform {
  required_version = ">= 1.3"

  # ============================================================
  # Remote Backend — S3 + DynamoDB state locking
  #
  # IMPORTANT: The bucket and DynamoDB table must exist before
  # running `terraform init` with this backend. Bootstrap them
  # first by temporarily commenting out this block, running:
  #   terraform init && terraform apply -target=aws_s3_bucket.tfstate \
  #     -target=aws_dynamodb_table.tfstate_lock
  # Then uncomment this block and run `terraform init` again to
  # migrate local state into the bucket.
  #
  # Values here cannot use variables — they must be hardcoded.
  # ============================================================
  backend "s3" {
    bucket         = "rke2-prod-tfstate-641275310402"
    key            = "state/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "rke2-prod-tfstate-lock"
    encrypt        = true
    # kms_key_id is optional here — the bucket's default KMS key
    # (set in aws_s3_bucket_server_side_encryption_configuration)
    # will be used automatically for state file encryption.
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.32"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = ">= 2"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.cluster_name
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

# ============================================================
# Data Sources
# ============================================================
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(var.tags, {
    Project     = var.cluster_name
    Environment = var.environment
  })
}

# ============================================================
# Bastion Module
# Creates the bastion EC2 instance, IAM instance profile,
# and SSH key pair. The instance ID is passed to networking
# so the EIP can be associated after the instance exists.
# ============================================================
module "bastion" {
  source = "../../modules/bastion"

  name                 = var.cluster_name
  vpc_id               = module.networking.vpc_id
  subnet_id            = module.networking.bastion_subnet_id
  security_group_id    = module.securitygroups.bastion_sg_id
  ami_id               = var.ami_id
  instance_type        = var.bastion_instance_type
  key_name             = aws_key_pair.rke2.key_name
  iam_instance_profile = aws_iam_instance_profile.bastion.name
  kubectl_version      = local.kubectl_version
  tags                 = local.tags
}

# ============================================================
# Networking Module
# VPC, subnets, IGW, NAT gateway, route tables, and EIPs.
# Depends on bastion for the bastion EIP association.
# ============================================================
module "networking" {
  source = "../../modules/networking"

  cluster_name              = var.cluster_name
  vpc_cidr                  = var.vpc_cidr
  bastion_subnet_cidr       = var.bastion_subnet_cidr
  control_plane_subnet_cidr = var.control_plane_subnet_cidr
  worker_subnet_cidr        = var.worker_subnet_cidr
  availability_zone         = var.availability_zone
  bastion_instance_id       = module.bastion.instance_id
  tags                      = local.tags
}

# ============================================================
# Security Groups Module
# Bastion, control plane, and worker security groups.
# ============================================================
module "securitygroups" {
  source = "../../modules/securitygroups"

  cluster_name = var.cluster_name
  vpc_id       = module.networking.vpc_id
  vpc_cidr     = var.vpc_cidr
  tags         = local.tags
}

# ============================================================
# RKE2 Module
# Control plane, worker nodepool, application NLB, and
# NLB listeners/target groups/ASG attachments.
# ============================================================
module "rke2" {
  source = "../../modules/rke2"

  cluster_name = var.cluster_name

  # Networking
  vpc_id                  = module.networking.vpc_id
  bastion_subnet_id       = module.networking.bastion_subnet_id
  control_plane_subnet_id = module.networking.control_plane_subnet_id
  worker_subnet_id        = module.networking.worker_subnet_id
  worker_nlb_eip_id       = module.networking.worker_nlb_eip_id

  # Security groups
  control_plane_sg_id = module.securitygroups.control_plane_sg_id
  workers_sg_id       = module.securitygroups.workers_sg_id

  # Compute
  ami_id                      = var.ami_id
  control_plane_instance_type = var.control_plane_instance_type
  worker_instance_type        = var.worker_instance_type
  control_plane_count         = var.control_plane_count
  worker_count                = var.worker_count
  worker_spot                 = var.worker_spot
  control_plane_disk_size_gb  = var.control_plane_disk_size_gb
  worker_disk_size_gb         = var.worker_disk_size_gb

  # SSH — key content read from disk via ssh_keys.tf locals
  ssh_public_key = local.ssh_public_key

  # RKE2
  rke2_version              = var.rke2_version
  rke2_channel              = var.rke2_channel
  wait_for_capacity_timeout = var.wait_for_capacity_timeout

  # Kubernetes networking
  pod_cidr     = var.pod_cidr
  service_cidr = var.service_cidr

  tags = local.tags
}

# ============================================================
# Outputs
# ============================================================
output "bastion_public_ip" {
  description = "Public IP (EIP) of the bastion host — SSH jump target"
  value       = module.networking.bastion_eip_public_ip
}

output "bastion_private_ip" {
  description = "Private IP of the bastion host"
  value       = module.bastion.private_ip
}

output "control_plane_lb_dns" {
  description = "Internal DNS of the control plane NLB (access via bastion tunnel)"
  value       = module.rke2.server_url
}

output "app_nlb_public_ip" {
  description = "Public IP (EIP) of the application NLB facing worker nodes"
  value       = module.networking.worker_nlb_eip_public_ip
}

output "app_nlb_dns" {
  description = "DNS name of the application NLB"
  value       = module.rke2.app_nlb_dns
}

output "kubeconfig_s3_path" {
  description = "S3 path where the kubeconfig is stored after cluster bootstrap"
  value       = module.rke2.kubeconfig_path
}

output "cluster_name" {
  description = "RKE2 cluster name"
  value       = module.rke2.cluster_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "control_plane_subnet_id" {
  description = "Control plane subnet ID"
  value       = module.networking.control_plane_subnet_id
}

output "worker_subnet_id" {
  description = "Worker subnet ID"
  value       = module.networking.worker_subnet_id
}

output "nat_gateway_public_ip" {
  description = "Public IP of the NAT Gateway (used by private nodes for outbound traffic)"
  value       = module.networking.nat_gateway_public_ip
}

output "ebs_kms_key_arn" {
  description = "ARN of the KMS key used to encrypt all cluster EBS volumes"
  value       = aws_kms_key.ebs.arn
}

output "ebs_kms_key_id" {
  description = "ID of the KMS key used to encrypt all cluster EBS volumes"
  value       = aws_kms_key.ebs.key_id
}

output "ebs_kms_key_alias" {
  description = "Alias of the KMS key used to encrypt all cluster EBS volumes"
  value       = aws_kms_alias.ebs.name
}

output "tfstate_bucket" {
  description = "S3 bucket holding Terraform state, SSH public key, and outputs snapshot"
  value       = aws_s3_bucket.tfstate.bucket
}

output "tfstate_dynamodb_table" {
  description = "DynamoDB table used for Terraform state locking"
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "ssh_public_key_s3_path" {
  description = "S3 path of the uploaded SSH public key"
  value       = "s3://${aws_s3_bucket.tfstate.bucket}/${aws_s3_object.ssh_public_key.key}"
}

output "tf_outputs_s3_path" {
  description = "S3 path of the Terraform outputs JSON snapshot"
  value       = "s3://${aws_s3_bucket.tfstate.bucket}/${aws_s3_object.tf_outputs.key}"
}

output "ssh_connect_instructions" {
  description = "How to SSH into cluster nodes via bastion"
  value       = <<-INSTRUCTIONS
    # ---- SSH Access Instructions ----
    # 1. Add your private key to the SSH agent (enables agent forwarding):
    ssh-add ~/.ssh/id_rsa   # or your actual private key path

    # 2. SSH into the bastion (ForwardAgent enables jumping to internal nodes):
    ssh -A ubuntu@${module.networking.bastion_eip_public_ip}

    # 3. From the bastion, SSH into the control plane node (get IP from AWS console or below):
    ssh ubuntu@<control-plane-private-ip>

    # 4. From the bastion, SSH into a worker node:
    ssh ubuntu@<worker-private-ip>

    # ---- Alternatively: kubectl via kubeconfig from S3 ----
    # From the bastion:
    aws s3 cp ${module.rke2.kubeconfig_path} ~/.kube/config
    export KUBECONFIG=~/.kube/config
    kubectl get nodes
  INSTRUCTIONS
}

output "ssh_jump_command" {
  description = "Sample SSH jump command through the bastion to a cluster node"
  value       = module.bastion.ssh_jump_command
}

output "control_plane_private_ips" {
  description = "Private IPs of all running control plane nodes"
  value       = module.rke2.control_plane_private_ips
}

output "worker_private_ips" {
  description = "Private IPs of all running worker nodes"
  value       = module.rke2.worker_private_ips
}
