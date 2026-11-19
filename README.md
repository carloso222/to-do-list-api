# To-Do List API

API sencilla en Python + Flask para la actividad de EC2 (Desarrollo en la Nube, ITESO).

| Método | Ruta     | Descripción                                                   |
|--------|----------|---------------------------------------------------------------|
| GET    | `/tasks` | Regresa la lista de tareas                                    |
| POST   | `/tasks` | Agrega una tarea. Body: `{"tarea": "resolver actividad en equipo"}` |
| GET    | `/version` | Versión desplegada (variable de ambiente `APP_VERSION`, `dev` por default) |
| GET    | `/health` | Estado: conexión a la BD (`OK`/`FAIL`, con `SELECT 1`), versión y timestamp del servidor. HTTP 200 si está bien, 503 si la BD falla |

Las tareas se guardan en PostgreSQL (Amazon RDS). La app lee las credenciales de AWS Secrets Manager (variable `DB_SECRET_ID`); si esa variable no existe, por ejemplo en tu compu, usa una lista en memoria.

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

## Desplegar en EC2 con Terraform

Toda la infraestructura (key pair, security group e instancia) y el despliegue de la app salen de Terraform.
El `user_data` de la instancia clona este repo, instala dependencias y registra la app como servicio de systemd para que arranque en cada boot.

| Archivo               | Qué contiene |
|-----------------------|--------------|
| `main.tf`             | Provider, key pair, security groups (app y BD), RDS PostgreSQL, secreto en Secrets Manager e instancia EC2 |
| `variables.tf`        | Región, AMI, tipo de instancia, URL del repo, puerto |
| `outputs.tf`          | IP pública, URL de `/tasks`, comando SSH, endpoint de la BD y comando para consultarla |
| `user_data.sh.tftpl`  | Script de arranque: `git clone`, `pip install`, servicio systemd y comando `todo-db` (psql a RDS) |

```bash
terraform init      # descarga los providers
terraform plan      # muestra qué se va a crear
terraform apply     # lo crea (escribe "yes")
curl http://<IP>:5000/tasks
terraform output -raw consultar_db   # comando para ver la tabla tasks en RDS
terraform destroy   # borra todo al terminar
```

`terraform.tfstate` no se sube al repo (está en `.gitignore`) porque puede contener información sensible, incluida la llave privada.

## Deploy con un botón (GitHub Actions)

| Workflow | Qué hace |
|---|---|
| `Terraform apply` (`.github/workflows/terraform-apply.yml`) | Crea el bucket S3 del tfstate si no existe, y corre `init`, `plan` y `apply`. Al final muestra la IP de la EC2 en el resumen |
| `Terraform destroy` (`.github/workflows/terraform-destroy.yml`) | Corre `terraform destroy` (hay que escribir `destruir` para confirmar) |

Los dos se corren a mano desde la pestaña **Actions** (trigger `workflow_dispatch`).

**tfstate:** se guarda en S3, en el bucket `to-do-list-api-tfstate-<ID de la cuenta>` con versionado y lockfile nativo, así que GitHub Actions y tu compu comparten el mismo estado.

**GitHub Secrets necesarios** (Settings → Secrets and variables → Actions), que se actualizan en cada sandbox nuevo del Learner Lab:

| Secret | Valor |
|---|---|
| `AWS_ACCESS_KEY_ID` | De *AWS Details* en el Learner Lab |
| `AWS_SECRET_ACCESS_KEY` | De *AWS Details* en el Learner Lab |
| `AWS_SESSION_TOKEN` | De *AWS Details* en el Learner Lab |
| `EC2_HOST` | IP pública que muestra el workflow de apply al terminar |
| `SSH_PRIVATE_KEY` | Llave privada SSH fija (`~/.ssh/to-do-list-api`), la usa el deploy |

Y en la pestaña **Variables**: `SSH_PUBLIC_KEY` con el contenido de `~/.ssh/to-do-list-api.pub`.

**Correr Terraform en tu compu** usando el mismo estado en S3:

```bash
terraform init -reconfigure -backend-config="bucket=to-do-list-api-tfstate-<ID de la cuenta>"
```

## Pruebas unitarias

```bash
pip install -r requirements-dev.txt
pytest -v
```

Corren con la lista en memoria, así que no necesitan AWS.

## CI/CD

```
PR a main ──► CI (pytest) ──► merge permitido solo si pasa
git push origin v1.2.3 ──► Release (pytest + zip + GitHub Release) ──► Deploy a EC2
```

| Workflow | Trigger | Qué hace |
|---|---|---|
| `CI` (`ci.yml`) | PR hacia `main` (y push a `main`) | Corre `pytest`. La regla de protección de `main` exige el check **tests** |
| `Release` (`release.yml`) | Push de un tag `v#.#.#` | Corre las pruebas, comprime el repo con `git archive` y crea el release con el zip. Después dispara el deploy |
| `Monitoreo /health` (`monitoreo.yml`) | Cron cada 5 min (`schedule`), o a mano | Hace `GET /health` a la EC2 y falla si no responde 200. Solo corre si la variable `MONITOREO_ACTIVO` = `true` |
| `Deploy a EC2` (`deploy.yml`) | Release publicado (o a mano con un tag) | Por SSH, la EC2 descarga el zip del release, instala dependencias, cambia `/opt/todo-app/current` y reinicia el servicio (`deploy/deploy.sh`) |

Publicar una versión nueva:

```bash
git tag v1.0.0
git push origin v1.0.0
curl http://<IP>:5000/version   # {"version": "v1.0.0"}
```

> Un release creado con `GITHUB_TOKEN` no dispara el evento `release` en otros workflows (GitHub lo evita para no generar ciclos), por eso `release.yml` lanza `deploy.yml` con `gh workflow run`.


## Monitoreo con CloudWatch

### Estrategia de monitoreo

¿Cómo sabemos si la API funciona? Debe estar arriba, responder rápido, poder leer y escribir en RDS, y no regresar errores.

| Métrica | Origen | Qué responde | Alarma |
|---|---|---|---|
| `AWS/EC2 CPUUtilization` | AWS (nativa) | ¿La instancia está saturada? | `ec2-cpu-alta`: promedio > 80% en 5 min |
| `ToDoListApi DBErrors` | Instrumentada | ¿La app puede usar RDS? | `errores-bd`: ≥ 3 errores en 5 min |
| `ToDoListApi Requests` + `Errores5xx` | Instrumentada | ¿Qué porcentaje de requests falla? | `tasa-errores-5xx`: `100 * Errores5xx / Requests` > 10% en 5 min (solo si hubo ≥ 5 requests) |
| `ToDoListApi LatenciaMs` | Instrumentada | ¿La API responde lento? | `latencia-alta`: promedio > 1000 ms en 5 min |

- **Instrumentación** (`metricas.py`): cada request suma a `Requests` y, si responde 5xx, a `Errores5xx`. También registra su `LatenciaMs`. Cada falla al usar la BD suma a `DBErrors`. Las métricas se acumulan en memoria y se envían con `put_metric_data` una vez por minuto, para no hacer una llamada a AWS en cada request. Los contadores se mandan aunque valgan 0, para que las gráficas no tengan huecos.
- **Alarmas** (`cloudwatch.tf`): notifican por correo con SNS cuando se disparan (ALARM) y cuando se recuperan (OK). Usan `treat_missing_data = notBreaching`: si no llegan datos, no suenan.
- **Dashboard** (`cloudwatch.tf`): estado de las alarmas, requests y errores, tasa de error, latencia, errores de BD, CPU de la EC2 y CPU y conexiones de RDS.

Variable de GitHub necesaria: `ALARM_EMAIL` (pestaña Variables). Después de cada apply llega un correo de AWS para **confirmar la suscripción**.

### Probar las alarmas

```bash
# Tráfico normal (para ver datos en el dashboard)
bash scripts/generar-trafico.sh <IP> 60

# CPU alta: 2 procesos al 100% por 10 minutos (t3.micro tiene 2 vCPU)
ssh -i ~/.ssh/to-do-list-api ubuntu@<IP> "for i in 1 2; do timeout 600 yes > /dev/null & done"

# Errores de BD, tasa de errores y latencia: detener RDS, generar tráfico y volver a encenderlo
aws rds stop-db-instance --db-instance-identifier to-do-list-api-db
aws rds wait db-instance-stopped --db-instance-identifier to-do-list-api-db
bash scripts/generar-trafico.sh <IP> 40
aws rds start-db-instance --db-instance-identifier to-do-list-api-db

# Probar solo la notificación por correo (sin provocar la falla)
aws cloudwatch set-alarm-state --alarm-name to-do-list-api-latencia-alta --state-value ALARM --state-reason "Prueba de notificación"
```
