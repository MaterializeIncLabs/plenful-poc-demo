output "demo_url" {
  description = "Public URL of the demo app"
  value       = "http://${module.ec2.public_ip}"
}

output "app_public_ip" {
  description = "Elastic IP of the app server"
  value       = module.ec2.public_ip
}

output "rds_endpoint" {
  description = "Aurora Postgres endpoint"
  value       = module.rds.endpoint
}

output "rds_secret_arn" {
  description = "ARN of the RDS credentials secret in Secrets Manager"
  value       = module.rds.secret_arn
}

output "materialize_cluster" {
  description = "Materialize cluster name"
  value       = module.materialize.cluster_name
}
