variable "name" {
  description = "Name prefix"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the bastion (must be a public subnet)"
  type        = string
}

variable "security_group_id" {
  description = "Security group ID for the bastion"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the bastion host"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "AWS key pair name"
  type        = string
}

variable "iam_instance_profile" {
  description = "IAM instance profile name to attach to the bastion (for S3 kubeconfig access)"
  type        = string
  default     = ""
}

variable "kubectl_version" {
  description = <<-DESC
    kubectl version to install on the bastion (e.g. \"v1.26.15\").
    Should match the Kubernetes version embedded in rke2_version —
    strip the leading 'v' and the '+rke2rN' suffix from rke2_version,
    then re-add the 'v' prefix. The env layer derives this automatically
    via a local and passes it here.
  DESC
  type        = string
}

variable "tags" {
  description = "Tags to apply"
  type        = map(string)
  default     = {}
}
