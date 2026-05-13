variable "vpc_id" {}
variable "subnet_id" {}
variable "sg_app_id" {}
variable "rds_endpoint" {}
variable "rds_secret_arn" {}
variable "mz_host" {}
variable "mz_user" {}
variable "mz_password" { sensitive = true }
variable "mz_database" {}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_iam_role" "ec2" {
  name = "plenful-poc-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "secrets" {
  name = "plenful-poc-secrets-read"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.rds_secret_arn]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "plenful-poc-ec2-profile"
  role = aws_iam_role.ec2.name
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.sg_app_id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = base64encode(templatefile("${path.module}/userdata.sh.tpl", {
    rds_endpoint   = var.rds_endpoint
    rds_secret_arn = var.rds_secret_arn
    mz_host        = var.mz_host
    mz_user        = var.mz_user
    mz_password    = var.mz_password
    mz_database    = var.mz_database
    aws_region     = "us-east-1"
  }))

  tags = { Name = "plenful-poc-app-server" }
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = { Name = "plenful-poc-eip" }
}

output "public_ip" {
  value = aws_eip.app.public_ip
}

output "instance_id" {
  value = aws_instance.app.id
}
