variable "cluster_name" {
  description = "Name of the RKE2 cluster"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "bastion_subnet_cidr" {
  description = "CIDR for the bastion public subnet"
  type        = string
}

variable "control_plane_subnet_cidr" {
  description = "CIDR for the control-plane private subnet"
  type        = string
}

variable "worker_subnet_cidr" {
  description = "CIDR for the worker-node private subnet"
  type        = string
}

variable "availability_zone" {
  description = "Availability zone for all resources"
  type        = string
}

variable "bastion_instance_id" {
  description = "Instance ID of the bastion host (for EIP association)"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
