provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

provider "materialize" {
  host     = var.materialize_host
  username = var.materialize_user
  password = var.materialize_password
  database = var.materialize_database
  port     = 6875
}

module "networking" {
  source = "./modules/networking"
}

module "rds" {
  source      = "./modules/rds"
  vpc_id      = module.networking.vpc_id
  subnet_ids  = module.networking.subnet_ids
  sg_rds_id   = module.networking.sg_rds_id
  db_username = var.db_username
  db_password = var.db_password
}

module "ec2" {
  source           = "./modules/ec2"
  vpc_id           = module.networking.vpc_id
  subnet_id        = module.networking.subnet_ids[0]
  sg_app_id        = module.networking.sg_app_id
  rds_endpoint     = module.rds.endpoint
  rds_secret_arn   = module.rds.secret_arn
  mz_host          = var.materialize_host
  mz_user          = var.materialize_user
  mz_password      = var.materialize_password
  mz_database      = var.materialize_database
}

module "materialize" {
  source         = "./modules/materialize"
  rds_host       = module.rds.endpoint
  rds_port       = module.rds.port
  rds_dbname     = "plenful"
  rds_username   = var.db_username
  rds_password   = var.db_password
}
