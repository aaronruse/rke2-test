output "bastion_sg_id" {
  description = "Security group ID for the bastion host"
  value       = aws_security_group.bastion.id
}

output "control_plane_sg_id" {
  description = "Security group ID for control plane nodes"
  value       = aws_security_group.control_plane.id
}

output "workers_sg_id" {
  description = "Security group ID for worker nodes"
  value       = aws_security_group.workers.id
}
