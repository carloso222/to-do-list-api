"""API sencilla de lista de tareas (to-do list) con Flask.

Endpoints:
    GET  /tasks  -> regresa la lista de tareas
    POST /tasks  -> agrega una tarea. Body JSON: {"tarea": "texto de la tarea"}

Las tareas se guardan en memoria: si el servidor se reinicia, se pierden.
"""
from flask import Flask, jsonify, request

app = Flask(__name__)

# Lista en memoria donde se guardan las tareas
tareas = []


@app.get("/tasks")
def listar_tareas():
    return jsonify(tareas)


@app.post("/tasks")
def agregar_tarea():
    datos = request.get_json(silent=True)
    tarea = datos.get("tarea") if isinstance(datos, dict) else None

    if not isinstance(tarea, str) or not tarea.strip():
        return jsonify({"error": "Manda un JSON como {\"tarea\": \"texto\"}"}), 400

    tareas.append(tarea.strip())
    return jsonify({"tarea": tarea.strip()}), 201


if __name__ == "__main__":
    # host="0.0.0.0" para aceptar conexiones desde fuera de la máquina (necesario en EC2)
    app.run(host="0.0.0.0", port=5000)
