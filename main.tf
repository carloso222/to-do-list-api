terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

# Usa las credenciales del Learner Lab que están en ~/.aws/credentials
provider "aws" {
  region = var.region
}

# ---------- Red: la VPC default del Learner Lab ----------
data "aws_vpc" "default" {
  default = true
}

# Tu IP pública, para permitir SSH solo desde tu compu
data "http" "mi_ip" {
  url = "https://checkip.amazonaws.com"
}

# ---------- Key pair ----------
# Terraform genera la llave, sube la pública a AWS y guarda la privada en un .pem local.
# OJO: la llave privada también queda en terraform.tfstate; por eso el tfstate NO se sube al repo.
resource "tls_private_key" "llave" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "llave" {
  key_name   = "${var.nombre}-key"
  public_key = tls_private_key.llave.public_key_openssh
}

resource "local_sensitive_file" "llave_privada" {
  filename        = "${path.module}/${var.nombre}-key.pem"
  content         = tls_private_key.llave.private_key_openssh
  file_permission = "0400"
}

# ---------- Security group ----------
resource "aws_security_group" "app" {
  name        = "${var.nombre}-sg"
  description = "SSH desde mi IP y puerto de la app abierto"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH solo desde mi IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.mi_ip.response_body)}/32"]
  }

  ingress {
    description = "API to-do list"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Terraform borra la regla de salida que AWS pone por default, hay que declararla.
  # Sin esto la instancia no puede hacer apt-get ni git clone.
  egress {
    description = "Todo el trafico de salida"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.nombre}-sg"
  }
}

# ---------- Instancia EC2 ----------
resource "aws_instance" "app" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.llave.key_name
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = "LabInstanceProfile"

  # user_data: al arrancar, clona el repo, instala dependencias y levanta la app como servicio
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    repo_url = var.repo_url
    app_port = var.app_port
  })
  # Si cambias el user_data, Terraform recrea la instancia (el user_data solo corre en el primer boot)
  user_data_replace_on_change = true

  tags = {
    Name = var.nombre
  }
}
