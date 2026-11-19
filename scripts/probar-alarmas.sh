#!/usr/bin/env bash
# Prueba las 3 alarmas instrumentadas (errores-bd, tasa-errores-5xx, latencia-alta):
#   1) detiene RDS, 2) genera tráfico (falla porque no hay BD), 3) espera a que suenen las alarmas,
#   4) vuelve a encender RDS, 5) genera tráfico normal y espera a que regresen a OK.
# Tarda ~20-25 minutos. Necesita las credenciales del Learner Lab en ~/.aws/credentials.
# Uso (Git Bash):  bash scripts/probar-alarmas.sh <IP>
set -euo pipefail
cd "$(dirname "$0")/.."

IP="${1:?Uso: bash scripts/probar-alarmas.sh <IP>}"
DB="${DB:-to-do-list-api-db}"
export AWS_PAGER="" AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

aws_() { aws "$@" | tr -d '\r'; }
paso() { echo; echo "==> [$(date +%H:%M:%S)] $*"; }
ALARMAS_BD=(to-do-list-api-errores-bd to-do-list-api-tasa-errores-5xx to-do-list-api-latencia-alta)
esperar_alarmas() {  # esperar_alarmas <ALARM|OK> <segundos máximo>: revisa cada 20 s las 3 alarmas de la BD
  local objetivo=$1 fin=$((SECONDS + $2)) estados
  while (( SECONDS < fin )); do
    estados=$(aws_ cloudwatch describe-alarms --alarm-names "${ALARMAS_BD[@]}" \
      --query "MetricAlarms[].StateValue" --output text | tr '\t' ' ')
    printf '\r    Estados: %-30s (esperando %s)' "$estados" "$objetivo"
    if [ "$(tr ' ' '\n' <<< "$estados" | grep -cx "$objetivo")" -eq "${#ALARMAS_BD[@]}" ]; then
      echo; return 0
    fi
    sleep 20
  done
  echo; echo "    Se acabó el tiempo de espera; revisa el historial de las alarmas en CloudWatch."
}
estado_bd() {
  aws_ rds describe-db-instances --db-instance-identifier "$DB" \
    --query "DBInstances[0].DBInstanceStatus" --output text
}
esperar_bd() {  # esperar_bd <estado>   (el AWS CLI no tiene "wait db-instance-stopped")
  local actual
  while actual=$(estado_bd); [ "$actual" != "$1" ]; do
    printf '\r    Estado de la BD: %-12s (esperando "%s")' "$actual" "$1"
    sleep 15
  done
  printf '\r    Estado de la BD: %-12s                          \n' "$actual"
}
estado_alarmas() {
  aws_ cloudwatch describe-alarms --alarm-name-prefix to-do-list-api \
    --query "MetricAlarms[].{Alarma:AlarmName,Estado:StateValue}" --output table
}
trap 'echo; echo "Si la BD quedó detenida, enciéndela con: aws rds start-db-instance --db-instance-identifier $DB"' ERR INT

paso "Verificando credenciales de AWS"
aws_ sts get-caller-identity --query Arn --output text

paso "Estado inicial de las alarmas"
estado_alarmas

paso "1/5 Deteniendo la base de datos RDS (tarda ~5 minutos)"
case "$(estado_bd)" in
  stopping|stopped) echo "    La BD ya se está deteniendo o está detenida" ;;
  *) aws_ rds stop-db-instance --db-instance-identifier "$DB" --query DBInstance.DBInstanceStatus --output text ;;
esac
esperar_bd stopped

paso "2/5 Generando tráfico SIN base de datos (deben salir errores 500)"
bash scripts/generar-trafico.sh "$IP" 40

paso "3/5 Esperando a que suenen las alarmas (normalmente 1-3 minutos)"
esperar_alarmas ALARM 480
estado_alarmas
echo "    >>> AHORA: toma capturas de las alarmas en ALARM y del dashboard, y revisa tu correo."
echo "    >>> Presiona Enter para encender la base de datos otra vez."
read -r

paso "4/5 Encendiendo la base de datos RDS (tarda ~5-10 minutos)"
aws_ rds start-db-instance --db-instance-identifier "$DB" --query DBInstance.DBInstanceStatus --output text
esperar_bd available

paso "5/5 Generando tráfico normal y esperando a que las alarmas regresen a OK"
bash scripts/generar-trafico.sh "$IP" 20
esperar_alarmas OK 600
estado_alarmas
echo
echo "Listo. Las alarmas deben estar en OK otra vez y debió llegarte el correo de recuperación."
