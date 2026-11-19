"""API sencilla de lista de tareas (to-do list) con Flask + PostgreSQL (Amazon RDS).

Endpoints:
    GET  /tasks  -> regresa la lista de tareas
    POST /tasks  -> agrega una tarea. Body JSON: {"tarea": "texto de la tarea"}

Las credenciales de la base de datos NO están en el código: la app lee el secreto de
AWS Secrets Manager cuyo nombre viene en la variable de entorno DB_SECRET_ID.
La EC2 tiene permiso de leerlo gracias a su IAM role (LabInstanceProfile -> LabRole).

Si DB_SECRET_ID no está definida (por ejemplo, al correrla en tu compu), usa una lista en memoria.
"""
import json
import os
from functools import cache

from flask import Flask, jsonify, request

app = Flask(__name__)

DB_SECRET_ID = os.environ.get("DB_SECRET_ID")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

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


@app.get("/tasks")
def listar_tareas():
    if not DB_SECRET_ID:
        return jsonify(tareas_en_memoria)

    with conectar() as conn:
        filas = conn.execute("SELECT tarea FROM tasks ORDER BY id").fetchall()
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

    with conectar() as conn:
        nuevo_id = conn.execute(
            "INSERT INTO tasks (tarea) VALUES (%s) RETURNING id", (tarea,)
        ).fetchone()[0]
    return jsonify({"id": nuevo_id, "tarea": tarea}), 201


if __name__ == "__main__":
    if DB_SECRET_ID:
        crear_tabla()
        print("Usando base de datos RDS (secreto: %s)" % DB_SECRET_ID)
    else:
        print("DB_SECRET_ID no definida: usando lista en memoria")
    # host="0.0.0.0" para aceptar conexiones desde fuera de la máquina (necesario en EC2)
    app.run(host="0.0.0.0", port=5000)
