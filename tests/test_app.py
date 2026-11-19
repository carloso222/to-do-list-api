"""Pruebas unitarias de la API to-do.

Corren con la lista en memoria (sin DB_SECRET_ID), así no necesitan AWS ni base de datos.
Para correrlas:  pip install -r requirements-dev.txt  y luego  pytest
"""
from datetime import datetime

import pytest

import app as todo


@pytest.fixture
def cliente(monkeypatch):
    # Cada prueba empieza con una lista vacía y sin base de datos
    monkeypatch.setattr(todo, "DB_SECRET_ID", None)
    monkeypatch.setattr(todo, "tareas_en_memoria", [])
    todo.app.config["TESTING"] = True
    return todo.app.test_client()


def test_get_tasks_empieza_vacia(cliente):
    respuesta = cliente.get("/tasks")

    assert respuesta.status_code == 200
    assert respuesta.get_json() == []


def test_post_tasks_agrega_y_get_la_regresa(cliente):
    respuesta = cliente.post("/tasks", json={"tarea": "resolver actividad en equipo"})

    assert respuesta.status_code == 201
    assert respuesta.get_json() == {"tarea": "resolver actividad en equipo"}
    assert cliente.get("/tasks").get_json() == ["resolver actividad en equipo"]


@pytest.mark.parametrize("cuerpo", [{}, {"tarea": ""}, {"tarea": "   "}, {"tarea": 123}, {"otra": "x"}])
def test_post_tasks_invalido_regresa_400(cliente, cuerpo):
    respuesta = cliente.post("/tasks", json=cuerpo)

    assert respuesta.status_code == 400
    assert "error" in respuesta.get_json()
    assert cliente.get("/tasks").get_json() == []  # no se guardó nada


def test_get_version_regresa_la_variable_de_ambiente(cliente, monkeypatch):
    monkeypatch.setattr(todo, "APP_VERSION", "v1.2.3")

    respuesta = cliente.get("/version")

    assert respuesta.status_code == 200
    assert respuesta.get_json() == {"version": "v1.2.3"}


class ConexionFalsa:
    """Imita una conexión de psycopg para probar /health sin base de datos real."""

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def execute(self, query):
        assert query == "SELECT 1"
        return self

    def fetchone(self):
        return (1,)


def test_health_con_bd_ok_regresa_200(cliente, monkeypatch):
    monkeypatch.setattr(todo, "DB_SECRET_ID", "secreto-de-prueba")
    monkeypatch.setattr(todo, "APP_VERSION", "v1.1.0")
    monkeypatch.setattr(todo, "conectar", lambda: ConexionFalsa())

    respuesta = cliente.get("/health")
    datos = respuesta.get_json()

    assert respuesta.status_code == 200
    assert datos["status"] == "OK"
    assert datos["database"] == "OK"
    assert datos["version"] == "v1.1.0"
    assert datetime.fromisoformat(datos["timestamp"]).tzinfo is not None


def test_health_con_bd_caida_regresa_503(cliente, monkeypatch):
    def conectar_falla():
        raise OSError("connection refused")

    monkeypatch.setattr(todo, "DB_SECRET_ID", "secreto-de-prueba")
    monkeypatch.setattr(todo, "conectar", conectar_falla)

    respuesta = cliente.get("/health")

    assert respuesta.status_code == 503
    assert respuesta.get_json()["status"] == "FAIL"
    assert respuesta.get_json()["database"] == "FAIL"
