output "instance_id" {
  description = "EC2 instance ID of the bastion"
  value       = aws_instance.bastion.id
}

output "private_ip" {
  description = "Private IP of the bastion (not publicly routable)"
  value       = aws_instance.bastion.private_ip
}

output "ssh_jump_command" {
  description = "Sample SSH jump command through the bastion to a cluster node"
  value       = "ssh -A -J ubuntu@<bastion-public-ip> ubuntu@<target-private-ip>"
}
