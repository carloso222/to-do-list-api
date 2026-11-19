# To-Do List API

API sencilla en Python + Flask para la actividad de EC2 (Desarrollo en la Nube, ITESO).

| Método | Ruta     | Descripción                                                   |
|--------|----------|---------------------------------------------------------------|
| GET    | `/tasks` | Regresa la lista de tareas                                    |
| POST   | `/tasks` | Agrega una tarea. Body: `{"tarea": "resolver actividad en equipo"}` |

Las tareas se guardan en memoria (una lista de Python), así que se pierden al reiniciar el servidor.

## Correr en local (Windows, PowerShell)

```powershell
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
python app.py
```

El servidor queda escuchando en `http://localhost:5000`.

## Probar (en otra terminal)

PowerShell (usa `curl.exe`, no `curl`):

```powershell
curl.exe http://localhost:5000/tasks
curl.exe -X POST http://localhost:5000/tasks -H "Content-Type: application/json" -d '{\"tarea\": \"resolver actividad en equipo\"}'
curl.exe http://localhost:5000/tasks
```

O con `Invoke-RestMethod`:

```powershell
Invoke-RestMethod http://localhost:5000/tasks
Invoke-RestMethod -Method Post -Uri http://localhost:5000/tasks -ContentType "application/json" -Body '{"tarea": "resolver actividad en equipo"}'
```

Respuestas esperadas: `[]` al inicio, `201` al agregar, y la lista con la tarea al final. Si mandas el POST sin `tarea`, regresa `400`.

## Desplegar en EC2 (AWS Learner Lab)

Requisitos: lab iniciado, AWS CLI con las credenciales del lab en `~/.aws/credentials`, y Git Bash.

```bash
bash setup.sh      # crea key pair, security group e instancia EC2, copia el código con scp y arranca la app
bash teardown.sh   # borra la instancia, el security group y el key pair
```

| Archivo        | Qué hace |
|----------------|----------|
| `setup.sh`     | Crea los recursos (Ubuntu 26.04, t3.micro, us-east-1, LabInstanceProfile), copia `app.py` con `scp` y arranca el servidor |
| `user-data.sh` | Script que corre la instancia al crearse: instala `python3-venv` y `pip` |
| `teardown.sh`  | Borra todo lo creado (usa los IDs guardados en `.ec2-state`) |

La app queda en `http://<IP-pública>:5000/tasks`.
