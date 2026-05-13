variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "db_password" {
  description = "Aurora Postgres master password (pulled from env or tfvars)"
  type        = string
  sensitive   = true
}

variable "db_username" {
  description = "Aurora Postgres master username"
  type        = string
  default     = "plenful_admin"
}

variable "materialize_host" {
  description = "Materialize Cloud host (e.g. <id>.aws.materialize.cloud)"
  type        = string
}

variable "materialize_user" {
  description = "Materialize Cloud user (app password email)"
  type        = string
}

variable "materialize_password" {
  description = "Materialize Cloud app password"
  type        = string
  sensitive   = true
}

variable "materialize_database" {
  description = "Materialize database name"
  type        = string
  default     = "materialize"
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default = {
    project    = "plenful-poc"
    env        = "demo"
    managed-by = "terraform"
  }
}
