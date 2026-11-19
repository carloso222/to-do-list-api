output "instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "IP pública de la instancia"
  value       = aws_instance.app.public_ip
}

output "url_tasks" {
  description = "URL del endpoint /tasks"
  value       = "http://${aws_instance.app.public_ip}:${var.app_port}/tasks"
}

output "ssh" {
  description = "Comando para conectarse por SSH"
  value       = "ssh -i ${local.ruta_llave} ubuntu@${aws_instance.app.public_ip}"
}

output "db_endpoint" {
  description = "Host de la base de datos RDS (solo accesible desde la EC2)"
  value       = aws_db_instance.todo.address
}

output "db_secret_name" {
  description = "Nombre del secreto en Secrets Manager con las credenciales de la BD"
  value       = aws_secretsmanager_secret.db.name
}

output "consultar_db" {
  description = "Comando (Git Bash) para correr SELECT * FROM tasks en la BD a través de la EC2"
  value       = "ssh -i ${local.ruta_llave} ubuntu@${aws_instance.app.public_ip} \"todo-db -c 'SELECT * FROM tasks;'\""
}

output "version_url" {
  description = "URL del endpoint /version"
  value       = "http://${aws_instance.app.public_ip}:${var.app_port}/version"
}

output "dashboard_url" {
  description = "Dashboard de CloudWatch"
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${local.dashboard_name}"
}

output "sns_topic_arn" {
  description = "Tópico SNS de las alarmas"
  value       = aws_sns_topic.alarmas.arn
}
