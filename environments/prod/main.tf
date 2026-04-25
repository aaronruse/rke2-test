terraform {
  required_version = ">= 1.3"

  # ============================================================
  # Remote Backend — S3 + DynamoDB state locking
  # Bucket and table are provisioned by environments/bootstrap/
  # ============================================================
  backend "s3" {
    bucket         = "rke2-prod-tfstate-641275310402"
    key            = "state/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "rke2-prod-tfstate-lock"
    encrypt        = true
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
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
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

  # Bucket name matches what bootstrap creates — must stay in sync
  # with the bucket_name local in environments/bootstrap/main.tf
  tfstate_bucket = "${var.cluster_name}-tfstate-${data.aws_caller_identity.current.account_id}"
}

# ============================================================
# Bastion Module
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
# Control plane and workers use the locally generated node key
# (aws_key_pair.node) — separate from the bastion key.
# The node private key lives only on the local filesystem and
# is never stored in Terraform state or S3.
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

  # SSH — node key generated locally, public key read from disk.
  # Private key is never stored in state or S3.
  ssh_public_key = data.local_file.node_ssh_public_key.content

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
# Destroy-time precondition check
# Fails terraform destroy with a clear message if the control
# plane ASG still has suspended processes, which means the
# cluster was stopped with cluster-stop.sh and not started
# again. Destroying in this state causes the ASG drain to
# hang until it times out.
#
# To destroy safely:
#   1. bash scripts/cluster-start.sh
#   2. terraform destroy
# ============================================================
resource "null_resource" "check_cluster_started_before_destroy" {
  triggers = {
    # Derive the CP ASG name from the worker nodepool ID by replacing
    # "workers-agent" with "server" — same convention used in
    # modules/rke2/outputs.tf. Both ASGs share the same random suffix.
    cp_asg_name = replace(module.rke2.worker_nodepool_id, "workers-agent", "server")
    region      = var.aws_region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      SUSPENDED=$(aws autoscaling describe-auto-scaling-groups \
        --region "${self.triggers.region}" \
        --auto-scaling-group-names "${self.triggers.cp_asg_name}" \
        --query "AutoScalingGroups[0].SuspendedProcesses[0].ProcessName" \
        --output text)

      if [ -n "$SUSPENDED" ] && [ "$SUSPENDED" != "None" ]; then
        echo ""
        echo "============================================================"
        echo "ERROR: Cannot destroy — cluster is in a stopped state."
        echo ""
        echo "The control plane ASG has suspended processes, which means"
        echo "cluster-stop.sh was run and the cluster has not been started"
        echo "again. Destroying now will cause terraform to hang."
        echo ""
        echo "Start the cluster first, then destroy:"
        echo "  bash scripts/cluster-start.sh"
        echo "  terraform destroy"
        echo "============================================================"
        echo ""
        exit 1
      fi

      echo "Cluster state check passed — control plane ASG processes are active."
    EOT
  }
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
  value       = "s3://${local.tfstate_bucket}/kubeconfig/config"
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

output "tfstate_bucket" {
  description = "S3 bucket holding Terraform state, SSH keys, kubeconfig, and outputs"
  value       = local.tfstate_bucket
}

output "ssh_public_key_s3_path" {
  description = "S3 path of the uploaded bastion SSH public key"
  value       = "s3://${local.tfstate_bucket}/ssh/rke2_id_ed25519.pub"
}

output "ssh_private_key_s3_path" {
  description = "S3 path of the uploaded bastion SSH private key"
  value       = "s3://${local.tfstate_bucket}/ssh/rke2_id_ed25519"
}

output "tf_outputs_s3_path" {
  description = "S3 path of the Terraform outputs JSON snapshot"
  value       = "s3://${local.tfstate_bucket}/outputs/terraform.json"
}

output "node_ssh_key_path" {
  description = "Local filesystem path of the generated node SSH private key"
  value       = pathexpand(var.node_ssh_private_key_path)
}

output "ssh_connect_instructions" {
  description = "How to SSH into cluster nodes via bastion"
  value       = <<-INSTRUCTIONS
    # ---- SSH Access Instructions ----

    # Bastion uses your local key (~/.ssh/rke2_id_ed25519)
    # Cluster nodes use the locally generated node key.

    # 1. Load both keys into the SSH agent:
    ssh-add ~/.ssh/rke2_id_ed25519
    ssh-add ${pathexpand(var.node_ssh_private_key_path)}

    # 2. SSH into the bastion:
    ssh -A ubuntu@${module.networking.bastion_eip_public_ip}

    # 3. From the bastion, SSH into a control plane or worker node:
    ssh ubuntu@<node-private-ip>

    # ---- Fetch kubeconfig from S3 ----
    aws s3 cp s3://${local.tfstate_bucket}/kubeconfig/config ~/.kube/config \
      --region ${var.aws_region}
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
