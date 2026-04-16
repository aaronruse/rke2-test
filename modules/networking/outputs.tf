output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "bastion_subnet_id" {
  description = "Public bastion subnet ID"
  value       = aws_subnet.bastion.id
}

output "control_plane_subnet_id" {
  description = "Control plane private subnet ID"
  value       = aws_subnet.control_plane.id
}

output "worker_subnet_id" {
  description = "Worker private subnet ID"
  value       = aws_subnet.workers.id
}

output "bastion_eip_public_ip" {
  description = "Public IP (EIP) of the bastion host"
  value       = aws_eip.bastion.public_ip
}

output "worker_nlb_eip_id" {
  description = "Allocation ID of the worker NLB EIP"
  value       = aws_eip.worker_nlb.id
}

output "worker_nlb_eip_public_ip" {
  description = "Public IP of the worker NLB EIP"
  value       = aws_eip.worker_nlb.public_ip
}

output "nat_gateway_public_ip" {
  description = "Public IP of the NAT Gateway"
  value       = aws_eip.nat.public_ip
}
