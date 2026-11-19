"""API sencilla de lista de tareas (to-do list) con Flask + PostgreSQL (Amazon RDS).

Endpoints:
    GET  /tasks    -> regresa la lista de tareas
    POST /tasks    -> agrega una tarea. Body JSON: {"tarea": "texto de la tarea"}
    GET  /version  -> regresa la versión desplegada (variable de ambiente APP_VERSION)
    GET  /health   -> estado de la app: conexión a la BD (OK/FAIL), versión y hora del servidor

Las credenciales de la base de datos NO están en el código: la app lee el secreto de
AWS Secrets Manager cuyo nombre viene en la variable de entorno DB_SECRET_ID.
La EC2 tiene permiso de leerlo gracias a su IAM role (LabInstanceProfile -> LabRole).

Si DB_SECRET_ID no está definida (por ejemplo, al correrla en tu compu), usa una lista en memoria.

Monitoreo: cada request registra métricas (Requests, Errores5xx, LatenciaMs, DBErrors) que se
envían a CloudWatch una vez por minuto (ver metricas.py). Solo se envían cuando corre en AWS.
"""
import json
import logging
import os
import time
from datetime import datetime, timezone
from functools import cache

from flask import Flask, g, jsonify, request

from metricas import Metricas

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

app = Flask(__name__)

DB_SECRET_ID = os.environ.get("DB_SECRET_ID")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
# La pone el deploy (el tag del release, ej. v1.0.0). Si no existe, estamos en desarrollo.
APP_VERSION = os.environ.get("APP_VERSION", "dev")
# Namespace de las métricas en CloudWatch (debe coincidir con el de las alarmas en Terraform)
METRICS_NAMESPACE = os.environ.get("METRICS_NAMESPACE", "ToDoListApi")

metricas = Metricas(namespace=METRICS_NAMESPACE, region=AWS_REGION)

tareas_en_memoria = []  # solo se usa si no hay base de datos configurada


@cache
def datos_conexion():
    """Lee usuario, contraseña, host, puerto y nombre de la BD desde Secrets Manager (una sola vez)."""
    import boto3

    cliente = boto3.client("secretsmanager", region_name=AWS_REGION)
    secreto = json.loads(cliente.get_secret_value(SecretId=DB_SECRET_ID)["SecretString"])
    return {
        "host": secreto["host"],
        "port": secreto["port"],
        "user": secreto["username"],
        "password": secreto["password"],
        "dbname": secreto["dbname"],
    }


def conectar():
    import psycopg

    return psycopg.connect(**datos_conexion(), connect_timeout=5)


def crear_tabla():
    with conectar() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                id         SERIAL PRIMARY KEY,
                tarea      TEXT        NOT NULL,
                creada_en  TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )


# ---------- Instrumentación: métricas de cada request ----------
@app.before_request
def iniciar_cronometro():
    g.inicio = time.perf_counter()


@app.after_request
def registrar_metricas(respuesta):
    inicio = g.pop("inicio", None)
    if inicio is not None:
        metricas.latencia((time.perf_counter() - inicio) * 1000)
    metricas.contar("Requests")
    if respuesta.status_code >= 500:
        metricas.contar("Errores5xx")
    return respuesta


def error_de_bd(accion):
    """Registra un error de base de datos (métrica DBErrors + log) y regresa una respuesta 500."""
    metricas.contar("DBErrors")
    app.logger.exception("Error de base de datos al %s", accion)
    return jsonify({"error": "Error de base de datos"}), 500


@app.get("/version")
def version():
    return jsonify({"version": APP_VERSION})


@app.get("/health")
def health():
    """Health check: 200 si todo está bien, 503 si la base de datos no responde."""
    if not DB_SECRET_ID:
        estado_bd = "NO_CONFIGURADA"  # modo local con lista en memoria
    else:
        try:
            with conectar() as conn:
                conn.execute("SELECT 1").fetchone()
            estado_bd = "OK"
        except Exception:
            # El detalle va al log del servidor (journalctl -u todo-app), no a la respuesta pública
            metricas.contar("DBErrors")
            app.logger.exception("Health check: falló la conexión a la base de datos")
            estado_bd = "FAIL"

    codigo = 503 if estado_bd == "FAIL" else 200
    return jsonify(
        {
            "status": "OK" if codigo == 200 else "FAIL",
            "database": estado_bd,
            "version": APP_VERSION,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
    ), codigo


@app.get("/tasks")
def listar_tareas():
    if not DB_SECRET_ID:
        return jsonify(tareas_en_memoria)

    try:
        with conectar() as conn:
            filas = conn.execute("SELECT tarea FROM tasks ORDER BY id").fetchall()
    except Exception:
        return error_de_bd("listar tareas")
    return jsonify([fila[0] for fila in filas])


@app.post("/tasks")
def agregar_tarea():
    datos = request.get_json(silent=True)
    tarea = datos.get("tarea") if isinstance(datos, dict) else None

    if not isinstance(tarea, str) or not tarea.strip():
        return jsonify({"error": "Manda un JSON como {\"tarea\": \"texto\"}"}), 400
    tarea = tarea.strip()

    if not DB_SECRET_ID:
        tareas_en_memoria.append(tarea)
        return jsonify({"tarea": tarea}), 201

    try:
        with conectar() as conn:
            nuevo_id = conn.execute(
                "INSERT INTO tasks (tarea) VALUES (%s) RETURNING id", (tarea,)
            ).fetchone()[0]
    except Exception:
        return error_de_bd("guardar la tarea")
    return jsonify({"id": nuevo_id, "tarea": tarea}), 201


if __name__ == "__main__":
    if DB_SECRET_ID:
        crear_tabla()
        print("Usando base de datos RDS (secreto: %s)" % DB_SECRET_ID)
        metricas.iniciar()  # solo en AWS: enviar métricas a CloudWatch cada minuto
    else:
        print("DB_SECRET_ID no definida: usando lista en memoria (sin métricas en CloudWatch)")
    # host="0.0.0.0" para aceptar conexiones desde fuera de la máquina (necesario en EC2)
    app.run(host="0.0.0.0", port=5000)
