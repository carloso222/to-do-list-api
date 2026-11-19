# =====================================================================
#  Monitoreo con Amazon CloudWatch: SNS (correo), alarmas y dashboard
# =====================================================================
#
#  Estrategia de monitoreo (ver README):
#    | Alarma             | Métrica                          | Origen        | Condición                       |
#    |--------------------|----------------------------------|---------------|---------------------------------|
#    | ec2-cpu-alta       | AWS/EC2 CPUUtilization           | AWS (nativa)  | Promedio > 80% en 5 min         |
#    | errores-bd         | ToDoListApi DBErrors             | Instrumentada | >= 3 errores en 5 min           |
#    | tasa-errores-5xx   | ToDoListApi Errores5xx/Requests  | Instrumentada | > 10% (con >= 5 requests) 5 min |
#    | latencia-alta      | ToDoListApi LatenciaMs           | Instrumentada | Promedio > 1000 ms en 5 min     |

locals {
  # Debe coincidir con METRICS_NAMESPACE de app.py
  metrics_namespace = "ToDoListApi"
  dashboard_name    = "${var.nombre}-dashboard"
}

# ---------- SNS: a dónde llegan las alarmas ----------
resource "aws_sns_topic" "alarmas" {
  name = "${var.nombre}-alarmas"
}

# AWS manda un correo de confirmación: hay que dar clic en "Confirm subscription" para recibir alarmas
resource "aws_sns_topic_subscription" "correo" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarmas.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------- Alarma 1 (métrica de AWS): CPU de la EC2 ----------
resource "aws_cloudwatch_metric_alarm" "ec2_cpu_alta" {
  alarm_name          = "${var.nombre}-ec2-cpu-alta"
  alarm_description   = "La CPU de la EC2 de la app supera el 80% en promedio durante 5 minutos"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = aws_instance.app.id }
  statistic           = "Average"
  period              = 300 # monitoreo básico de EC2: un dato cada 5 minutos
  evaluation_periods  = 1
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarmas.arn]
  ok_actions          = [aws_sns_topic.alarmas.arn]
}

# ---------- Alarma 2 (instrumentada): errores de base de datos ----------
resource "aws_cloudwatch_metric_alarm" "errores_bd" {
  alarm_name          = "${var.nombre}-errores-bd"
  alarm_description   = "La app tuvo 3 o más errores al usar la base de datos RDS en 5 minutos"
  namespace           = local.metrics_namespace
  metric_name         = "DBErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarmas.arn]
  ok_actions          = [aws_sns_topic.alarmas.arn]
}

# ---------- Alarma 3 (instrumentada): tasa de errores 5xx (metric math) ----------
# Una cantidad de errores sola no dice nada: 5 errores en 10 requests es grave, en 1M no.
# Solo se evalúa si hubo al menos 5 requests, para no alarmar por 1 error en 1 request.
resource "aws_cloudwatch_metric_alarm" "tasa_errores" {
  alarm_name          = "${var.nombre}-tasa-errores-5xx"
  alarm_description   = "Más del 10% de los requests a la API regresan error 5xx (5 minutos, mínimo 5 requests)"
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarmas.arn]
  ok_actions          = [aws_sns_topic.alarmas.arn]

  metric_query {
    id          = "tasa"
    expression  = "IF(requests >= 5, 100 * errores / requests, 0)"
    label       = "Tasa de errores 5xx (%)"
    return_data = true
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = local.metrics_namespace
      metric_name = "Requests"
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "errores"
    metric {
      namespace   = local.metrics_namespace
      metric_name = "Errores5xx"
      period      = 300
      stat        = "Sum"
    }
  }
}

# ---------- Alarma 4 (instrumentada): latencia ----------
resource "aws_cloudwatch_metric_alarm" "latencia_alta" {
  alarm_name          = "${var.nombre}-latencia-alta"
  alarm_description   = "Los requests a la API tardan más de 1 segundo en promedio durante 5 minutos"
  namespace           = local.metrics_namespace
  metric_name         = "LatenciaMs"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarmas.arn]
  ok_actions          = [aws_sns_topic.alarmas.arn]
}

# ---------- Dashboard ----------
resource "aws_cloudwatch_dashboard" "app" {
  dashboard_name = local.dashboard_name

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "alarm"
        x      = 0
        y      = 0
        width  = 24
        height = 3
        properties = {
          title = "Estado de las alarmas"
          alarms = [
            aws_cloudwatch_metric_alarm.ec2_cpu_alta.arn,
            aws_cloudwatch_metric_alarm.errores_bd.arn,
            aws_cloudwatch_metric_alarm.tasa_errores.arn,
            aws_cloudwatch_metric_alarm.latencia_alta.arn,
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 3
        width  = 12
        height = 6
        properties = {
          title  = "Requests y errores 5xx (por minuto)"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            [local.metrics_namespace, "Requests", { label = "Requests" }],
            [local.metrics_namespace, "Errores5xx", { label = "Errores 5xx", color = "#d62728" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 3
        width  = 12
        height = 6
        properties = {
          title  = "Tasa de errores 5xx (%)"
          region = var.region
          view   = "timeSeries"
          period = 300
          metrics = [
            [{ expression = "IF(r >= 5, 100 * e / r, 0)", label = "Tasa de errores %", id = "tasa" }],
            [local.metrics_namespace, "Requests", { id = "r", stat = "Sum", visible = false }],
            [local.metrics_namespace, "Errores5xx", { id = "e", stat = "Sum", visible = false }],
          ]
          annotations = { horizontal = [{ value = 10, label = "Umbral de alarma (10%)" }] }
          yAxis       = { left = { min = 0 } }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 9
        width  = 12
        height = 6
        properties = {
          title  = "Latencia de la API (ms)"
          region = var.region
          view   = "timeSeries"
          period = 60
          metrics = [
            [local.metrics_namespace, "LatenciaMs", { stat = "Average", label = "Promedio" }],
            [local.metrics_namespace, "LatenciaMs", { stat = "Maximum", label = "Máximo" }],
          ]
          annotations = { horizontal = [{ value = 1000, label = "Umbral de alarma (1000 ms)" }] }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 9
        width  = 12
        height = 6
        properties = {
          title  = "Errores de base de datos (por minuto)"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            [local.metrics_namespace, "DBErrors", { label = "DBErrors", color = "#d62728" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 15
        width  = 12
        height = 6
        properties = {
          title  = "CPU de la EC2 (%)"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app.id, { label = "CPU EC2" }],
          ]
          annotations = { horizontal = [{ value = 80, label = "Umbral de alarma (80%)" }] }
          yAxis       = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 15
        width  = 12
        height = 6
        properties = {
          title  = "Base de datos RDS"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.todo.identifier, { label = "CPU RDS (%)" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.todo.identifier, { label = "Conexiones", yAxis = "right" }],
          ]
        }
      },
    ]
  })
}
