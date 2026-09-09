output "vpc_id" {
  description = "ID of the new DataLake POC VPC. Feed into each POC module's vpc_id variable."
  value       = aws_vpc.datalake_poc.id
}

output "vpc_cidr" {
  value = aws_vpc.datalake_poc.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs. Feed into each POC module's private_subnet_ids variable."
  value       = aws_subnet.private[*].id
}

output "private_route_table_id" {
  description = "Route table ID for the private subnets. Feed into each POC module's route_table_ids variable (as a single-element list)."
  value       = aws_route_table.private.id
}

output "peering_connection_id" {
  value = aws_vpc_peering_connection.to_rds_vpc.id
}

output "s3_gateway_endpoint_id" {
  description = "S3 gateway endpoint already created here — pass create_s3_gateway_endpoint = false to poc2-dms-landing to avoid a duplicate."
  value       = aws_vpc_endpoint.s3.id
}

output "bastion_instance_id" {
  description = "Temporary bastion instance ID — use with `aws ssm start-session` for one-off private-network access (e.g. to the RDS instance). No SSH, no public IP."
  value       = aws_instance.bastion.id
}
