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
  value       = "ssh -i ${local_sensitive_file.llave_privada.filename} ubuntu@${aws_instance.app.public_ip}"
}
