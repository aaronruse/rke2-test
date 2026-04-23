# ============================================================
# General
# ============================================================
variable "cluster_name" {
  description = "Name of the RKE2 cluster"
  type        = string
}

# ============================================================
# Networking inputs (from networking module)
# ============================================================
variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "bastion_subnet_id" {
  description = "Public bastion subnet ID (used for NLB subnet mapping)"
  type        = string
}

variable "control_plane_subnet_id" {
  description = "Private subnet ID for control plane nodes"
  type        = string
}

variable "worker_subnet_id" {
  description = "Private subnet ID for worker nodes"
  type        = string
}

variable "worker_nlb_eip_id" {
  description = "Allocation ID of the worker NLB EIP"
  type        = string
}

# ============================================================
# Security group inputs (from securitygroups module)
# ============================================================
variable "control_plane_sg_id" {
  description = "Security group ID for control plane nodes"
  type        = string
}

variable "workers_sg_id" {
  description = "Security group ID for worker nodes"
  type        = string
}

# ============================================================
# Compute
# ============================================================
variable "ami_id" {
  description = "AMI ID for all cluster nodes"
  type        = string
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for control plane nodes"
  type        = string
  default     = "c5.2xlarge"
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.xlarge"
}

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
# SSH
# ============================================================
variable "ssh_public_key" {
  description = "SSH public key content to inject into cluster nodes"
  type        = string
}

# ============================================================
# RKE2
# ============================================================
variable "rke2_version" {
  description = "RKE2 version to install (e.g. v1.26.15+rke2r1)"
  type        = string
}

variable "rke2_channel" {
  description = "RKE2 channel (overridden when rke2_version is pinned)"
  type        = string
  default     = null
}

variable "wait_for_capacity_timeout" {
  description = <<-DESC
    How long Terraform waits for the control plane ASG instances to register
    as healthy before timing out. CIS hardened images take longer to bootstrap.
  DESC
  type        = string
  default     = "20m"
}

# ============================================================
# Kubernetes Networking
# ============================================================
variable "pod_cidr" {
  description = "CIDR block for Kubernetes pods (overlay network)"
  type        = string
}

variable "service_cidr" {
  description = "CIDR block for Kubernetes services (ClusterIP range)"
  type        = string
}

# ============================================================
# Tags
# ============================================================
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
