# =============================================================
# terraform.tfvars — fill in your values before running
# =============================================================

aws_region   = "us-west-2"
cluster_name = "rke2-prod"
environment  = "prod"

# ------- Networking -------
vpc_cidr                  = "10.0.0.0/16"
bastion_subnet_cidr       = "10.0.0.0/24"
control_plane_subnet_cidr = "10.0.1.0/24"
worker_subnet_cidr        = "10.0.2.0/24"
availability_zone         = "us-west-2a"

# ------- RKE2 -------
# CIS hardened images take longer to bootstrap than standard images.
# Increase the ASG health check wait timeout to avoid false timeout errors.
wait_for_capacity_timeout = "20m"
# ⚠️  RKE2 v1.26 is EOL. Plan upgrade to 1.28+ after initial deployment.
rke2_version        = "v1.26.15+rke2r1"
control_plane_count = 1   # Change to 3 for production HA
worker_count        = 4

# Spot instances for workers — true = spot (~60-70% cost saving), false = On-Demand
# The ASG max is automatically set to worker_count + 2 when spot is enabled,
# giving headroom for replacement nodes before interrupted ones are terminated.
worker_spot         = true

# ------- Compute -------
control_plane_instance_type = "t3.xlarge"
worker_instance_type        = "t3.2xlarge"
bastion_instance_type       = "t3.small"
control_plane_disk_size_gb  = 200
worker_disk_size_gb         = 350

# ------- AMI -------
# Subscribe to CIS Hardened Ubuntu 24.04 Level 1 in AWS Marketplace first:
# https://aws.amazon.com/marketplace/pp/prodview-6l5e56nst6r3g
# here is the CIS AMI=ami-004ca9c8986f68ab5
# here is another CIS image=ami-0d76b909de1a0595d
# Then replace this with the AMI ID for your region:
ami_id = "ami-0650f6c65227d92b1"

# ------- SSH -------
ssh_public_key_path = "~/.ssh/rke2_id_ed25519.pub"

# ------- Kubernetes Networking -------
pod_cidr     = "10.42.0.0/16"
service_cidr = "10.43.0.0/16"

tags = {
  Team = "platform-engineering"
}
