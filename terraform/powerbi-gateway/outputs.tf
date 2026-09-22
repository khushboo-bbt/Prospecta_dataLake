output "gateway_instance_id" {
  description = "Use with `aws ec2 get-password-data` (Windows admin password) and `aws ssm start-session` (RDP port forwarding) - see README.md."
  value       = aws_instance.gateway.id
}

output "gateway_private_ip" {
  value = aws_instance.gateway.private_ip
}

output "gateway_security_group_id" {
  description = "Feed into another POC module's own security-group wiring, or into this module's own *_redshift_security_group_id variable for a POC not yet wired up at first apply."
  value       = aws_security_group.gateway.id
}

output "gateway_key_pair_name" {
  value = aws_key_pair.gateway.key_name
}

output "nat_gateway_public_ip" {
  description = "Public IP the gateway's outbound traffic (Power BI cloud service, Windows Update) appears to come from. Useful if the Power BI tenant ever needs an IP allow-list entry."
  value       = aws_eip.nat.public_ip
}
