#!/usr/bin/env bash
# Borra todo lo que creó setup.sh: instancia EC2, security group y key pair.
# Uso (en Git Bash): bash teardown.sh
set -uo pipefail
cd "$(dirname "$0")"

REGION="${REGION:-us-east-1}"
NAME="${NAME:-todo-app}"
SG_NAME="${NAME}-sg"
KEY_NAME="${NAME}-key"
KEY_FILE="${KEY_NAME}.pem"
STATE_FILE=".ec2-state"
INSTANCE_ID=""
SG_ID=""

export AWS_PAGER=""
export MSYS_NO_PATHCONV=1
aws_() { aws --region "$REGION" "$@" | tr -d '\r'; }
paso() { echo; echo "==> $*"; }

# Leer los IDs que guardó setup.sh (si existe el archivo)
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

paso "Instancia EC2"
# Si no hay ID guardado, buscar por el tag Name
if [[ -z "$INSTANCE_ID" ]]; then
  INSTANCE_ID=$(aws_ ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text)
fi
if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
  # shellcheck disable=SC2086
  aws_ ec2 terminate-instances --instance-ids $INSTANCE_ID --query "TerminatingInstances[].[InstanceId,CurrentState.Name]" --output text
  echo "Esperando a que termine (el security group no se puede borrar antes)..."
  # shellcheck disable=SC2086
  aws_ ec2 wait instance-terminated --instance-ids $INSTANCE_ID && echo "Instancia terminada"
else
  echo "No hay instancia que borrar"
fi

paso "Security group"
if [[ -z "$SG_ID" ]]; then
  SG_ID=$(aws_ ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" \
    --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
fi
if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
  for i in 1 2 3 4 5 6; do
    if aws_ ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null; then echo "SG $SG_ID borrado"; break; fi
    if [[ $i -eq 6 ]]; then echo "No se pudo borrar $SG_ID; intenta de nuevo en un minuto"; fi
    sleep 10
  done
else
  echo "No hay security group que borrar"
fi

paso "Key pair"
aws_ ec2 delete-key-pair --key-name "$KEY_NAME" > /dev/null && echo "Key pair $KEY_NAME borrado en AWS"
if [[ -f "$KEY_FILE" ]]; then
  chmod 600 "$KEY_FILE" 2>/dev/null
  rm -f "$KEY_FILE" && echo "Llave local $KEY_FILE borrada"
fi

rm -f "$STATE_FILE"

paso "Instancias restantes en $REGION"
aws_ ec2 describe-instances \
  --query "Reservations[*].Instances[*].{ID:InstanceId,Name:Tags[?Key=='Name']|[0].Value,State:State.Name}" \
  --output table
