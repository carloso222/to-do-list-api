#!/usr/bin/env bash
# Crea una instancia EC2 en AWS Learner Lab y despliega la app to-do.
# Uso (en Git Bash, con el lab iniciado y credenciales en ~/.aws/credentials):
#   bash setup.sh
set -euo pipefail
cd "$(dirname "$0")"

# ---------- Configuración (las 9 decisiones de EC2) ----------
REGION="${REGION:-us-east-1}"                 # 3. Red: región
NAME="${NAME:-todo-app}"                      # 7. Tag Name
AMI_ID="${AMI_ID:-ami-0b6d9d3d33ba97d99}"     # 1. AMI: Ubuntu Server 26.04 LTS (lista del Learner Lab)
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"    # 2. Tipo de instancia
INSTANCE_PROFILE="LabInstanceProfile"         # 4. IAM role (LabRole vía instance profile)
USER_DATA_FILE="user-data.sh"                 # 5. User data
                                              # 6. Almacenamiento: default (8 GB EBS)
SG_NAME="${NAME}-sg"                          # 8. Security group
KEY_NAME="${NAME}-key"                        # 9. Key pair
KEY_FILE="${KEY_NAME}.pem"
APP_PORT=5000                                 # Debe coincidir con el puerto de app.py
SSH_USER="ubuntu"
STATE_FILE=".ec2-state"                       # Aquí se guardan los IDs para teardown.sh

export AWS_PAGER=""          # Evita que el AWS CLI abra un paginador y se quede esperando
export MSYS_NO_PATHCONV=1    # Evita que Git Bash convierta argumentos que empiezan con / en rutas de Windows

# En Windows el AWS CLI regresa saltos de línea \r\n; quitamos el \r para que las variables queden limpias
aws_() { aws --region "$REGION" "$@" | tr -d '\r'; }
paso() { echo; echo "==> $*"; }
guardar() { echo "$1=$2" >> "$STATE_FILE"; }

trap 'echo; echo "ERROR: algo falló. Corre \"bash teardown.sh\" para borrar lo que se alcanzó a crear."' ERR

if [[ -f "$STATE_FILE" ]]; then
  echo "Ya existe $STATE_FILE (hay recursos creados). Corre primero: bash teardown.sh"
  exit 1
fi

paso "Verificando credenciales de AWS"
aws_ sts get-caller-identity --query Arn --output text

paso "Red: buscando la VPC"
VPC_ID=$(aws_ ec2 describe-vpcs --filters Name=is-default,Values=true --query "Vpcs[0].VpcId" --output text)
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  VPC_ID=$(aws_ ec2 describe-vpcs --query "Vpcs[0].VpcId" --output text)
fi
echo "VPC: $VPC_ID"

paso "Key pair: creando $KEY_NAME"
KEY_MATERIAL=$(aws_ ec2 create-key-pair --key-name "$KEY_NAME" --query KeyMaterial --output text)
guardar KEY_NAME "$KEY_NAME"
printf '%s\n' "$KEY_MATERIAL" > "$KEY_FILE"
chmod 400 "$KEY_FILE"
echo "Llave privada guardada en $KEY_FILE (está en .gitignore, no se sube al repo)"

paso "Security group: creando $SG_NAME"
MY_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com | tr -d '\r\n' || true)
SSH_CIDR="${SSH_CIDR:-${MY_IP:+$MY_IP/32}}"
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"
SG_ID=$(aws_ ec2 create-security-group --group-name "$SG_NAME" \
  --description "SG para la app to-do: SSH y puerto de la app" \
  --vpc-id "$VPC_ID" --query GroupId --output text)
guardar SG_ID "$SG_ID"
# Regla 1: SSH (22) solo desde tu IP
aws_ ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$SSH_CIDR" > /dev/null
# Regla 2: el puerto de la app (5000) abierto para todos. ESTO es lo que "falta" en el ejemplo de clase.
aws_ ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port "$APP_PORT" --cidr 0.0.0.0/0 > /dev/null
echo "SG: $SG_ID  (22 desde $SSH_CIDR, $APP_PORT desde 0.0.0.0/0)"

paso "Lanzando instancia EC2 ($INSTANCE_TYPE, $AMI_ID)"
INSTANCE_ID=$(aws_ ec2 run-instances \
  --image-id "$AMI_ID" \
  --count 1 \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=$INSTANCE_PROFILE" \
  --user-data "file://$USER_DATA_FILE" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
  --query "Instances[0].InstanceId" --output text)
guardar INSTANCE_ID "$INSTANCE_ID"
echo "Instancia: $INSTANCE_ID. Esperando a que esté 'running'..."
aws_ ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$(aws_ ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
guardar PUBLIC_IP "$PUBLIC_IP"
echo "IP pública: $PUBLIC_IP"

SSH_OPTS=(-i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
DEST="$SSH_USER@$PUBLIC_IP"

paso "Esperando a que SSH responda"
for i in $(seq 1 40); do
  if ssh "${SSH_OPTS[@]}" "$DEST" true 2>/dev/null; then echo "SSH listo"; break; fi
  if [[ $i -eq 40 ]]; then echo "SSH no respondió"; false; fi
  sleep 5
done

paso "Esperando a que termine el user data (instalar venv y pip)"
ssh "${SSH_OPTS[@]}" "$DEST" "cloud-init status --wait > /dev/null || true"

paso "Copiando el código con scp"
ssh "${SSH_OPTS[@]}" "$DEST" "mkdir -p ~/todo-app"
scp "${SSH_OPTS[@]}" app.py requirements.txt "$DEST:~/todo-app/"

paso "Instalando dependencias y arrancando el servidor en la instancia"
ssh "${SSH_OPTS[@]}" "$DEST" '
  set -e
  cd ~/todo-app
  python3 -m venv venv
  venv/bin/pip install -q -r requirements.txt
  nohup venv/bin/python app.py > app.log 2>&1 < /dev/null &
  sleep 3
  echo "Respuesta desde dentro de la instancia: $(curl -s localhost:5000/tasks)"
'

paso "Probando la app desde tu computadora"
RESPUESTA=$(curl -s --max-time 10 "http://$PUBLIC_IP:$APP_PORT/tasks" || true)
echo "GET http://$PUBLIC_IP:$APP_PORT/tasks -> ${RESPUESTA:-(sin respuesta)}"

trap - ERR
cat <<FIN

=====================================================
 Listo. La app está corriendo en EC2:
   http://$PUBLIC_IP:$APP_PORT/tasks

 Conectarte por SSH:
   ssh -i $KEY_FILE $DEST

 Cuando terminen, BORRA todo con:
   bash teardown.sh
=====================================================
FIN
