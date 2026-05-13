variable "vpc_id" {}
variable "subnet_ids" { type = list(string) }
variable "sg_rds_id" {}
variable "db_username" {}
variable "db_password" { sensitive = true }

resource "aws_db_subnet_group" "main" {
  name       = "plenful-poc-rds-subnet-group"
  subnet_ids = var.subnet_ids

  tags = { Name = "plenful-poc-rds-subnet-group" }
}

resource "aws_rds_cluster_parameter_group" "main" {
  name        = "plenful-poc-aurora-pg16"
  family      = "aurora-postgresql16"
  description = "Plenful POC — logical replication enabled"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "wal_level"
    value        = "logical"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_replication_slots"
    value        = "10"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_wal_senders"
    value        = "10"
    apply_method = "pending-reboot"
  }

  tags = { Name = "plenful-poc-aurora-pg16" }
}

resource "aws_rds_cluster" "main" {
  cluster_identifier      = "plenful-poc-aurora"
  engine                  = "aurora-postgresql"
  engine_version          = "16.2"
  database_name           = "plenful"
  master_username         = var.db_username
  master_password         = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [var.sg_rds_id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.main.name
  skip_final_snapshot     = true
  deletion_protection     = false
  storage_encrypted       = true

  tags = { Name = "plenful-poc-aurora" }
}

resource "aws_rds_cluster_instance" "main" {
  identifier         = "plenful-poc-aurora-instance"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.t3.medium"
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version
  publicly_accessible = true

  tags = { Name = "plenful-poc-aurora-instance" }
}

resource "aws_secretsmanager_secret" "rds_creds" {
  name                    = "plenful-poc/rds-credentials"
  recovery_window_in_days = 0

  tags = { Name = "plenful-poc-rds-credentials" }
}

resource "aws_secretsmanager_secret_version" "rds_creds" {
  secret_id = aws_secretsmanager_secret.rds_creds.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    host     = aws_rds_cluster.main.endpoint
    port     = 5432
    dbname   = "plenful"
  })
}

output "endpoint" {
  value = aws_rds_cluster.main.endpoint
}

output "port" {
  value = aws_rds_cluster.main.port
}

output "secret_arn" {
  value = aws_secretsmanager_secret.rds_creds.arn
}
