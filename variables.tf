variable "region" {
  type        = string
  description = "Región de AWS (Learner Lab: us-east-1 o us-west-2)"
  default     = "us-east-1"
}

variable "nombre" {
  type        = string
  description = "Prefijo para nombrar los recursos (tag Name, key pair, security group)"
  default     = "to-do-list-api"
}

variable "ami_id" {
  type        = string
  description = "AMI de Ubuntu Server 26.04 LTS en us-east-1 (lista del Learner Lab)"
  default     = "ami-0b6d9d3d33ba97d99"
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia (Learner Lab soporta t3 nano a large)"
  default     = "t3.micro"
}

variable "repo_url" {
  type        = string
  description = "URL del repositorio PÚBLICO que la instancia va a clonar"
  default     = "https://github.com/carloso222/to-do-list-api.git"
}

variable "app_port" {
  type        = number
  description = "Puerto donde escucha la app (debe coincidir con app.py)"
  default     = 5000
}

variable "db_instance_class" {
  type        = string
  description = "Tipo de instancia de RDS (Learner Lab: db.t3 micro/small/medium)"
  default     = "db.t3.micro"
}

variable "db_engine_version" {
  type        = string
  description = "Versión mayor de PostgreSQL (AWS elige la versión menor por default)"
  default     = "17"
}
