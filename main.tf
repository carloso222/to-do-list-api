terraform {
  # 1.10+ para poder usar el lockfile nativo de S3 (sin DynamoDB)
  required_version = ">= 1.10"

  # El tfstate vive en S3 para que GitHub Actions (y tu compu) compartan el mismo estado.
  # El bucket se pasa en "terraform init -backend-config=bucket=..." porque su nombre lleva el ID de la cuenta.
  backend "s3" {
    key          = "to-do-list-api/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # evita que dos "apply" corran al mismo tiempo sobre el mismo estado
  }

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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Credenciales: en tu compu salen de ~/.aws/credentials; en GitHub Actions de las variables
# de entorno AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY y AWS_SESSION_TOKEN (GitHub Secrets)
provider "aws" {
  region = var.region
}

# ---------- Red: la VPC default del Learner Lab ----------
data "aws_vpc" "default" {
  default = true
}

# Tu IP pública, para permitir SSH solo desde tu compu cuando corres Terraform localmente
data "http" "mi_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  # Si ssh_cidr viene vacío usamos la IP de quien corre Terraform.
  # En GitHub Actions esa sería la IP del runner, por eso el workflow sí manda ssh_cidr.
  ssh_cidr = var.ssh_cidr != "" ? var.ssh_cidr : "${chomp(data.http.mi_ip.response_body)}/32"
}

# ---------- Key pair ----------
# Opción A (GitHub Actions / CD): usas TU llave pública fija (variable ssh_public_key).
#   La privada vive en GitHub Secrets (SSH_PRIVATE_KEY) y sirve para todos los sandboxes.
# Opción B (si ssh_public_key viene vacía): Terraform genera una llave y guarda la privada
#   en un .pem local. OJO: esa llave privada también queda en el tfstate.
locals {
  ssh_public_key = trimspace(var.ssh_public_key) # quita saltos de línea que se cuelan al pegarla
}

resource "tls_private_key" "llave" {
  count     = local.ssh_public_key == "" ? 1 : 0
  algorithm = "ED25519"
}

resource "aws_key_pair" "llave" {
  key_name   = "${var.nombre}-key"
  public_key = coalesce(local.ssh_public_key, one(tls_private_key.llave[*].public_key_openssh))
}

resource "local_sensitive_file" "llave_privada" {
  count           = local.ssh_public_key == "" ? 1 : 0
  filename        = "${path.module}/${var.nombre}-key.pem"
  content         = tls_private_key.llave[0].private_key_openssh
  file_permission = "0400"
}

locals {
  # Ruta de la llave privada para los comandos de los outputs
  ruta_llave = coalesce(one(local_sensitive_file.llave_privada[*].filename), "~/.ssh/${var.nombre}")
}

# ---------- Security group ----------
resource "aws_security_group" "app" {
  name        = "${var.nombre}-sg"
  description = "SSH restringido y puerto de la app abierto"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.ssh_cidr]
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

# ---------- Base de datos: Amazon RDS (PostgreSQL) ----------
# Contraseña aleatoria: nadie la escribe ni la ve; se guarda en Secrets Manager.
# OJO: también queda en terraform.tfstate, otra razón para NO subir el tfstate al repo.
resource "random_password" "db" {
  length  = 24
  special = false
}

# Security group de la BD: solo acepta PostgreSQL (5432) que venga del security group de la app.
# Así ni Internet ni otra máquina pueden conectarse a la base de datos.
resource "aws_security_group" "db" {
  name        = "${var.nombre}-db-sg"
  description = "PostgreSQL solo desde el security group de la app"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "PostgreSQL desde la EC2 de la app"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    description = "Todo el trafico de salida"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.nombre}-db-sg"
  }
}

resource "aws_db_instance" "todo" {
  identifier        = "${var.nombre}-db"
  engine            = "postgres"
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class
  allocated_storage = 20

  db_name  = "todo"
  username = "todoadmin"
  password = random_password.db.result

  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false # la BD no tiene IP pública

  # Para el sandbox: sin respaldos ni snapshot final, así se crea y se destruye más rápido
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = {
    Name = "${var.nombre}-db"
  }
}

# ---------- Secrets Manager: credenciales de la BD ----------
# La app lee este secreto al arrancar; no hay usuario ni contraseña en el código ni en el repo.
resource "aws_secretsmanager_secret" "db" {
  name        = "${var.nombre}-db-credentials"
  description = "Credenciales de la BD RDS de la app to-do"

  # Borrar de inmediato al hacer destroy (si no, AWS lo guarda 7-30 dias y el nombre queda ocupado)
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.todo.address
    port     = aws_db_instance.todo.port
    dbname   = aws_db_instance.todo.db_name
    username = aws_db_instance.todo.username
    password = random_password.db.result
  })
}

# ---------- Instancia EC2 ----------
resource "aws_instance" "app" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.llave.key_name
  vpc_security_group_ids = [aws_security_group.app.id]

  # IAM role: así un servicio de AWS (EC2) obtiene permiso para usar otro (Secrets Manager).
  # El Learner Lab no deja crear roles, así que usamos LabInstanceProfile (rol LabRole).
  # En una cuenta normal crearías un aws_iam_role con una policy que permita
  # "secretsmanager:GetSecretValue" solo sobre aws_secretsmanager_secret.db.arn,
  # y un aws_iam_instance_profile para asignarlo a la instancia.
  iam_instance_profile = "LabInstanceProfile"

  # user_data: al arrancar, clona el repo, instala dependencias y levanta la app como servicio
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    repo_url     = var.repo_url
    app_port     = var.app_port
    region       = var.region
    db_secret_id = aws_secretsmanager_secret.db.name
  })
  # Si cambias el user_data, Terraform recrea la instancia (el user_data solo corre en el primer boot)
  user_data_replace_on_change = true

  # La app necesita que la BD y el secreto ya existan cuando arranca
  depends_on = [aws_secretsmanager_secret_version.db]

  # La llave SSH solo se instala al crear la instancia: si cambia el key pair, hay que recrearla
  lifecycle {
    replace_triggered_by = [aws_key_pair.llave]
  }

  tags = {
    Name = var.nombre
  }
}
