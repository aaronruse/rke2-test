output "server_url" {
  description = "Internal DNS of the control plane NLB (access via bastion tunnel)"
  value       = module.rke2.server_url
}

output "cluster_name" {
  description = "RKE2 cluster name"
  value       = module.rke2.cluster_name
}

output "kubeconfig_path" {
  description = "S3 path where the kubeconfig is stored after cluster bootstrap"
  value       = module.rke2.kubeconfig_path
}

output "app_nlb_dns" {
  description = "DNS name of the application NLB"
  value       = aws_lb.app.dns_name
}

output "worker_nodepool_id" {
  description = "ASG name of the worker nodepool"
  value       = module.rke2_workers.nodepool_id
}

# ============================================================
# KMS Key Outputs
# ============================================================

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

# ============================================================
# Node IP Outputs
# The CP ASG name is derived from the worker nodepool_id by
# replacing "workers-agent" with "server" — both are created
# by the rancherfederal module with the same naming convention
# and the same random suffix, so this is always in sync.
# e.g. rke2-prod-3wh-workers-agent-rke2-nodepool
#   -> rke2-prod-3wh-server-rke2-nodepool
# ============================================================
locals {
  cp_asg_name = replace(module.rke2_workers.nodepool_id, "workers-agent", "server")
}

data "aws_instances" "control_plane" {
  filter {
    name   = "tag:aws:autoscaling:groupName"
    values = [local.cp_asg_name]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

data "aws_instances" "workers" {
  filter {
    name   = "tag:aws:autoscaling:groupName"
    values = [module.rke2_workers.nodepool_id]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

output "control_plane_private_ips" {
  description = "Private IPs of all running control plane nodes"
  value       = data.aws_instances.control_plane.private_ips
}

output "worker_private_ips" {
  description = "Private IPs of all running worker nodes"
  value       = data.aws_instances.workers.private_ips
}
