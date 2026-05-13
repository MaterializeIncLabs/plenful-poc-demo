data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "plenful-poc-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "plenful-poc-igw" }
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "plenful-poc-public-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "plenful-poc-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Materialize Cloud egress IPs (us-east-1) — allow CDC replication into RDS
locals {
  materialize_egress_cidrs = [
    "52.3.135.64/32",
    "52.5.4.173/32",
    "54.197.145.252/32",
    "52.2.183.152/32",
    "54.196.23.52/32",
    "52.200.155.149/32"
  ]
}

resource "aws_security_group" "rds" {
  name        = "plenful-poc-sg-rds"
  description = "Allow Postgres from app server and Materialize Cloud"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from app server"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  dynamic "ingress" {
    for_each = local.materialize_egress_cidrs
    content {
      description = "Materialize Cloud CDC"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "plenful-poc-sg-rds" }
}

resource "aws_security_group" "app" {
  name        = "plenful-poc-sg-app"
  description = "App server: HTTP inbound, Postgres/Materialize outbound"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH (restrict to your IP in production)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "plenful-poc-sg-app" }
}
