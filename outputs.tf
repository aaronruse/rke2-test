# ============================================================
# Outputs
# ============================================================

output "bastion_public_ip" {
  description = "Public IP (EIP) of the bastion host — SSH jump target"
  value       = aws_eip.bastion.public_ip
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
  value       = aws_eip.worker_nlb.public_ip
}

output "app_nlb_dns" {
  description = "DNS name of the application NLB"
  value       = aws_lb.app.dns_name
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
  value       = aws_vpc.main.id
}

output "control_plane_subnet_id" {
  description = "Control plane subnet ID"
  value       = aws_subnet.control_plane.id
}

output "worker_subnet_id" {
  description = "Worker subnet ID"
  value       = aws_subnet.workers.id
}

output "nat_gateway_public_ip" {
  description = "Public IP of the NAT Gateway (used by private nodes for outbound traffic)"
  value       = aws_eip.nat.public_ip
}

output "ssh_connect_instructions" {
  description = "How to SSH into cluster nodes via bastion"
  value       = <<-INSTRUCTIONS
    # ---- SSH Access Instructions ----

    # 1. Add your private key to the SSH agent (enables agent forwarding):
    ssh-add ~/.ssh/id_rsa   # or your actual private key path

    # 2. SSH into the bastion (ForwardAgent enables jumping to internal nodes):
    ssh -A ubuntu@${aws_eip.bastion.public_ip}

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
