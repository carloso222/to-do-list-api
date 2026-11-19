#!/bin/bash
# Despliega un release en la EC2. Lo ejecuta el workflow "Deploy a EC2" por SSH, como root:
#   ssh ubuntu@EC2 "sudo bash -s -- <tag> <url-del-zip>" < deploy/deploy.sh
# 1) descarga el zip del release, 2) instala dependencias, 3) cambia el symlink "current",
# 4) actualiza APP_VERSION y 5) reinicia el servicio.
set -euo pipefail
export PIP_DISABLE_PIP_VERSION_CHECK=1

TAG="$1"
ZIP_URL="$2"
BASE=/opt/todo-app
DESTINO="$BASE/releases/$TAG"
TMP=$(mktemp -d)

echo "==> Descargando $ZIP_URL"
curl -fsSL "$ZIP_URL" -o "$TMP/release.zip"

echo "==> Descomprimiendo en $DESTINO"
python3 -m zipfile -e "$TMP/release.zip" "$TMP/extraido"
rm -rf "$DESTINO"
# El zip trae todo dentro de una carpeta to-do-list-api/
mv "$TMP/extraido/to-do-list-api" "$DESTINO"
rm -rf "$TMP"

echo "==> Instalando dependencias"
"$BASE/venv/bin/pip" install -q -r "$DESTINO/requirements.txt"
chown -R ubuntu:ubuntu "$DESTINO"

echo "==> Activando $TAG y reiniciando el servidor"
ln -sfn "$DESTINO" "$BASE/current"
echo "APP_VERSION=$TAG" > "$BASE/app.env"
systemctl restart todo-app

# Esperar a que la app responda con la versión nueva
for _ in $(seq 1 20); do
  if RESPUESTA=$(curl -fsS http://localhost:5000/version 2>/dev/null); then
    echo "==> La app responde: $RESPUESTA"
    exit 0
  fi
  sleep 2
done
echo "La app no respondió después del reinicio" >&2
journalctl -u todo-app -n 30 --no-pager >&2
exit 1
