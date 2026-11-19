"""Pruebas unitarias de la API to-do.

Corren con la lista en memoria (sin DB_SECRET_ID), así no necesitan AWS ni base de datos.
Para correrlas:  pip install -r requirements-dev.txt  y luego  pytest
"""
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
