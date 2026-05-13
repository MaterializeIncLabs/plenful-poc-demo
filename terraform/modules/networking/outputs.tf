output "vpc_id" {
  value = aws_vpc.main.id
}

output "subnet_ids" {
  value = aws_subnet.public[*].id
}

output "sg_rds_id" {
  value = aws_security_group.rds.id
}

output "sg_app_id" {
  value = aws_security_group.app.id
}
