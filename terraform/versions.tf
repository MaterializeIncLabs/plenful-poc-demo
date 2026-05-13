terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    materialize = {
      source  = "MaterializeInc/materialize"
      version = "~> 0.8"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
