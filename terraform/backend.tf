terraform {
  backend "s3" {
    bucket = "materialize-poc-tfstate"
    key    = "plenful-poc-demo/terraform.tfstate"
    region = "us-east-1"
  }
}
