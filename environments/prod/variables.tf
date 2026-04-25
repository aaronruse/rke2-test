# ============================================================
# General
# ============================================================
variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the RKE2 cluster"
  type        = string
  default     = "rke2-cluster"

  validation {
    condition     = length(var.cluster_name) <= 24
    error_message = "cluster_name must be 24 characters or fewer (rke2-aws-tf module constraint)."
  }
}

variable "environment" {
  description = "Environment label (e.g. dev, staging, prod)"
  type        = string
  default     = "prod"
}

# ============================================================
# Networking
# ============================================================
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "control_plane_subnet_cidr" {
  description = "CIDR for the control-plane private subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "worker_subnet_cidr" {
  description = "CIDR for the worker-node private subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "bastion_subnet_cidr" {
  description = "CIDR for the bastion public subnet"
  type        = string
  default     = "10.0.0.0/24"
}

variable "availability_zone" {
  description = "Availability zone for all resources. Use a single AZ for this single-CP deployment."
  type        = string
  default     = "us-east-1a"
}

# ============================================================
# RKE2 Cluster Settings
# ============================================================
variable "rke2_version" {
  description = "RKE2 version to install (e.g. v1.26.15+rke2r1)"
  type        = string
  default     = "v1.26.15+rke2r1"
}

# Derive the kubectl version from rke2_version by stripping the '+rke2rN' suffix.
# e.g. "v1.26.15+rke2r1" → "v1.26.15"
# This local is consumed by the bastion module so kubectl always matches the cluster.
locals {
  kubectl_version = "v${split("+", trimprefix(var.rke2_version, "v"))[0]}"
}

variable "rke2_channel" {
  description = "RKE2 channel to use (overridden by rke2_version when version is pinned)"
  type        = string
  default     = null
}

# NOTE: Per your request this is set to 1 control plane node.
# IMPORTANT: Production best practice is 3 control plane nodes for etcd HA quorum.
# Change this to 3 for any production workload.
variable "control_plane_count" {
  description = "Number of control plane / server nodes. 1 is non-HA; use 3 for production."
  type        = number
  default     = 1
}

variable "worker_count" {
  description = "Number of worker (agent) nodes"
  type        = number
  default     = 4
}

variable "worker_spot" {
  description = <<-DESC
    Enable EC2 spot instances for worker nodes.
    Spot is ~60-70%% cheaper than On-Demand but AWS may reclaim instances
    with a 2-minute warning. The ASG will replace interrupted nodes automatically
    and RKE2 will reschedule pods onto the replacement node.
    Recommended for stateless workloads. Set to false for stateful or
    strict-availability workloads.
  DESC
  type        = bool
  default     = true
}

# ============================================================
# Compute — Instance Types & Storage
# ============================================================
variable "control_plane_instance_type" {
  description = "EC2 instance type for control plane nodes"
  type        = string
  default     = "t3.xlarge"
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.2xlarge"
}

variable "bastion_instance_type" {
  description = "EC2 instance type for the bastion host"
  type        = string
  default     = "t3.small"
}

variable "control_plane_disk_size_gb" {
  description = "Root EBS volume size in GB for control plane nodes"
  type        = number
  default     = 200
}

variable "worker_disk_size_gb" {
  description = "Root EBS volume size in GB for worker nodes"
  type        = number
  default     = 350
}

# ============================================================
# AMI — CIS Hardened Ubuntu 24.04
# ============================================================
variable "ami_id" {
  description = "AMI ID for CIS Hardened Ubuntu 24.04 LTS (must be subscribed in AWS Marketplace)"
  type        = string
  default     = "ami-REPLACE-WITH-CIS-UBUNTU-2404"
}

# ============================================================
# SSH Access
# ============================================================
variable "ssh_public_key_path" {
  description = <<-DESC
    Path to the SSH public key file for bastion access.
    The corresponding private key must be present on the machine
    running Terraform. The public key is stored in S3 for auditing.
    Default: ~/.ssh/rke2_id_ed25519.pub
  DESC
  type        = string
  default     = "~/.ssh/rke2_id_ed25519.pub"
}

variable "node_ssh_private_key_path" {
  description = <<-DESC
    Path where Terraform will generate the SSH private key for
    cluster node access (control plane and workers). The key is
    generated on the local filesystem during apply and is never
    stored in Terraform state or S3. The public key is derived
    from this path by appending .pub and is registered in AWS.
    Default: ~/.ssh/rke2_node_id_ed25519
  DESC
  type        = string
  default     = "~/.ssh/rke2_node_id_ed25519"
}

# ============================================================
# Timeouts
# ============================================================
variable "wait_for_capacity_timeout" {
  description = <<-DESC
    How long Terraform waits for the control plane ASG instances to register
    as healthy with the NLB before timing out. CIS hardened images take longer
    to bootstrap than standard images — 20m is recommended over the default 10m.
  DESC
  type        = string
  default     = "10m"
}

# ============================================================
# Kubernetes Networking
# ============================================================
variable "pod_cidr" {
  description = "CIDR block for Kubernetes pods (overlay network)"
  type        = string
  default     = "10.42.0.0/16"
}

variable "service_cidr" {
  description = "CIDR block for Kubernetes services (ClusterIP range)"
  type        = string
  default     = "10.96.0.0/12"
}

# ============================================================
# Tags
# ============================================================
variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
