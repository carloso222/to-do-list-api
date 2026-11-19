#!/usr/bin/env bash
# Genera tráfico a la API para ver las métricas en CloudWatch y probar las alarmas.
# Uso (Git Bash):  bash scripts/generar-trafico.sh <IP> [número de requests, default 60]
set -uo pipefail

IP="${1:?Uso: bash scripts/generar-trafico.sh <IP> [requests]}"
N="${2:-60}"
URL="http://${IP}:5000"
ok=0
errores=0

for i in $(seq 1 "$N"); do
  if (( i % 3 == 0 )); then
    codigo=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "$URL/tasks" \
      -H "Content-Type: application/json" -d "{\"tarea\": \"tarea de prueba $i\"}")
  else
    codigo=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$URL/tasks")
  fi
  if [[ "$codigo" == 2* ]]; then ok=$((ok + 1)); else errores=$((errores + 1)); fi
  printf '\r%d/%d requests   OK: %d   Errores: %d (último HTTP %s)' "$i" "$N" "$ok" "$errores" "$codigo"
  sleep 0.5
done
echo
echo "Las métricas llegan a CloudWatch cada minuto; las alarmas evalúan periodos de 5 minutos."
