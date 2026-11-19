# To-Do List API

API para gestionar tareas pendientes en Python y Flask. Las tareas se guardan en PostgreSQL (Amazon RDS) y la app corre en una instancia EC2. Toda la infraestructura se crea con **Terraform**, el ciclo de cambios está automatizado con **GitHub Actions** (CI, release y deploy) y el monitoreo se hace con **Amazon CloudWatch**.

## Arquitectura

```
                    GitHub (repo + Actions)
   PR ──► CI (pytest) ──► merge a main
   tag v#.#.# ──► Release (zip) ──► Deploy (SSH) ──────────────┐
   Terraform apply / destroy (manual) ──► tfstate en S3        │
   Monitoreo /health (cada 5 min) ─────────────┐               │
                                               ▼               ▼
 ┌──────────────────────── AWS (us-east-1, VPC default) ───────────────────────┐
 │  Security group app (22, 5000)          Security group BD (5432 solo desde app)
 │  ┌───────────────────────────┐   SQL    ┌──────────────────────────┐        │
 │  │ EC2 Ubuntu t3.micro       │ ───────► │ RDS PostgreSQL db.t3.micro│        │
 │  │ Flask :5000 (systemd)     │          └──────────────────────────┘        │
 │  │ IAM role: LabInstanceProfile ──► Secrets Manager (credenciales de la BD)  │
 │  └───────────┬───────────────┘                                              │
 │              │ put_metric_data (cada minuto)                                │
 │              ▼                                                              │
 │  CloudWatch: métricas ──► 4 alarmas ──► SNS ──► correo                      │
 │              └──► dashboard                                                 │
 └─────────────────────────────────────────────────────────────────────────────┘
```

## Endpoints

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/tasks` | Lista de tareas |
| POST | `/tasks` | Crea una tarea. Body: `{"tarea": "estudiar para el examen"}` |
| GET | `/version` | Versión desplegada (variable de ambiente `APP_VERSION`) |
| GET | `/health` | Conexión a la BD (`OK`/`FAIL` con `SELECT 1`), versión y timestamp. HTTP 200, o 503 si la BD falla |

```bash
curl -X POST http://<IP>:5000/tasks -H "Content-Type: application/json" -d '{"tarea": "estudiar para el examen"}'
curl http://<IP>:5000/tasks
curl http://<IP>:5000/version
curl http://<IP>:5000/health
```

## Estructura del repositorio

```
├── app.py                     API Flask (lee las credenciales de Secrets Manager)
├── metricas.py                Métricas personalizadas para CloudWatch (put_metric_data)
├── requirements.txt           Dependencias de la app
├── requirements-dev.txt       + pytest
├── tests/test_app.py          Pruebas unitarias
├── main.tf                    Backend S3, key pair, security groups, RDS, Secrets Manager, EC2
├── cloudwatch.tf              SNS, 4 alarmas y dashboard de CloudWatch
├── variables.tf / outputs.tf  Variables y salidas de Terraform
├── user_data.sh.tftpl         Arranque de la EC2: git clone, pip install, servicio systemd
├── deploy/deploy.sh           Lo que corre la EC2 en cada deploy
├── alerting/
│   ├── cloudwatch-dashboard.json   Configuración del dashboard (exportada de AWS)
│   └── alarms.json                 Configuración de las alarmas (exportada de AWS)
├── scripts/
│   ├── generar-trafico.sh     Genera requests para ver métricas
│   └── probar-alarmas.sh      Detiene RDS para disparar las alarmas y la vuelve a encender
└── .github/workflows/
    ├── terraform-apply.yml    Provisionar infraestructura (manual)
    ├── terraform-destroy.yml  Destruir infraestructura (manual)
    ├── ci.yml                 Pruebas en cada PR
    ├── release.yml            Tag v#.#.# → release con zip
    ├── deploy.yml             Release → deploy en la EC2
    └── monitoreo.yml          GET /health cada 5 minutos
```

## Configuración inicial (una sola vez)

**1. Llave SSH fija** para que el workflow de deploy entre a la EC2:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/to-do-list-api -N "" -C "deploy to-do-list-api"
```

**2. En GitHub, Settings → Secrets and variables → Actions:**

| Tipo | Nombre | Valor |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID` | Learner Lab → AWS Details (cambia en cada sandbox) |
| Secret | `AWS_SECRET_ACCESS_KEY` | Learner Lab → AWS Details (cambia en cada sandbox) |
| Secret | `AWS_SESSION_TOKEN` | Learner Lab → AWS Details (cambia en cada sandbox) |
| Secret | `SSH_PRIVATE_KEY` | Contenido de `~/.ssh/to-do-list-api` |
| Secret | `EC2_HOST` | IP pública de la EC2 (la muestra el workflow de apply) |
| Variable | `SSH_PUBLIC_KEY` | Contenido de `~/.ssh/to-do-list-api.pub` |
| Variable | `ALARM_EMAIL` | Correo que recibe las alarmas |
| Variable | `MONITOREO_ACTIVO` | `true` para que corra el monitoreo cada 5 min, `false` para pausarlo |

**3. Proteger `main`** (Settings → Branches → regla para `main`): *Require a pull request before merging* (sin approvals) y *Require status checks to pass* con el check **tests**.

## Crear la infraestructura

1. Inicia el Learner Lab y actualiza los 3 secrets de AWS.
2. **Actions → Terraform apply → Run workflow** (`ssh_cidr` = `0.0.0.0/0`, porque el deploy entra desde los runners de GitHub). Tarda ~10 min por el RDS.
3. Copia la IP del resumen al secret `EC2_HOST`.
4. Confirma la suscripción de SNS en el correo que te llega de AWS.

Al arrancar, la EC2 corre `user_data`: clona este repo, instala dependencias y levanta la app como servicio de systemd, sin SSH ni scp.

El **tfstate** se guarda en S3 (`to-do-list-api-tfstate-<cuenta>/to-do-list-api/terraform.tfstate`), con versionado y lockfile. Nunca se sube al repo (`.gitignore`).

## Destruir la infraestructura

1. Pon `MONITOREO_ACTIVO` en `false`.
2. **Actions → Terraform destroy → Run workflow** y escribe `destruir`.

## Correr en local y pruebas

```bash
python -m venv venv
source venv/Scripts/activate      # Windows (Git Bash). En Linux/Mac: source venv/bin/activate
pip install -r requirements-dev.txt
python app.py                     # sin DB_SECRET_ID usa una lista en memoria
pytest -v                         # pruebas unitarias
```

Para usar Terraform desde tu compu con el mismo estado:
```bash
terraform init -reconfigure -backend-config="bucket=to-do-list-api-tfstate-<ID de la cuenta>"
```

## CI/CD

```
PR a main ──► CI (pytest) ──► el merge solo se permite si pasa
git tag v1.2.0 && git push origin v1.2.0 ──► Release (pytest + zip + GitHub Release) ──► Deploy a EC2
```

| Workflow | Trigger | Qué hace |
|---|---|---|
| `CI` | PR hacia `main` | Corre `pytest`; la regla de `main` exige que pase |
| `Release` | Push de tag `v#.#.#` | Pruebas, `git archive` a zip y release en GitHub. Después dispara el deploy |
| `Deploy a EC2` | Release publicado (o manual con un tag) | Por SSH, la EC2 descarga el zip, instala dependencias, cambia `/opt/todo-app/current` y reinicia el servicio. Verifica con `GET /version` |
| `Monitoreo /health` | Cron `*/5 * * * *` | `GET /health`; falla si no responde 200 |

Un release creado con `GITHUB_TOKEN` no dispara el evento `release` en otros workflows (GitHub lo evita para no crear ciclos), por eso `release.yml` lanza `deploy.yml` con `gh workflow run`.

## Monitoreo con CloudWatch

### Métricas y alarmas

| Métrica | Origen | Qué responde | Alarma | Por qué ese umbral | Acción si suena |
|---|---|---|---|---|---|
| `AWS/EC2 CPUUtilization` | Nativa de AWS | ¿La instancia está saturada? | Promedio > 80% en 5 min | Una t3.micro sostenida arriba de 80% empieza a gastar créditos de CPU y responder lento; 5 min evita alarmas por picos cortos | Revisar en el dashboard si coincide con más requests; escalar el tipo de instancia o buscar un proceso colgado (`top`) |
| `ToDoListApi DBErrors` | Instrumentada | ¿La app puede leer y escribir en RDS? | ≥ 3 en 5 min | Un error aislado puede ser un timeout; 3 o más indican que la BD no responde | Revisar el estado de RDS y su security group, y `journalctl -u todo-app` |
| `ToDoListApi Requests` + `Errores5xx` | Instrumentada | ¿Qué porcentaje de requests falla? | `100*Errores5xx/Requests` > 10% (con ≥ 5 requests) en 5 min | La tasa importa más que el conteo; el mínimo de 5 requests evita alarmar por 1 error en 1 request | Ver qué endpoint falla en los logs; si coincide con `DBErrors`, la causa es la BD |
| `ToDoListApi LatenciaMs` | Instrumentada | ¿La API responde lento? | Promedio > 1000 ms en 5 min | La API normalmente responde en decenas de ms; más de 1 s es una degradación clara | Correlacionar con CPU de EC2 y RDS en el dashboard |

- **Instrumentación** (`metricas.py`): las métricas se acumulan en memoria y se envían con `put_metric_data` una vez por minuto, en lugar de una llamada por request. Los contadores se envían aunque valgan 0, para que las gráficas no tengan huecos.
- **Notificación:** las 4 alarmas avisan por correo con SNS al entrar en ALARM y al regresar a OK.
- **Dashboard:** estado de las alarmas, requests y errores, tasa de error, latencia, errores de BD, CPU de la EC2 y CPU y conexiones de RDS.
- Configuración: `cloudwatch.tf` (Terraform) y su exportación en `alerting/`.

### Probar las alarmas

```bash
# Tráfico normal
bash scripts/generar-trafico.sh <IP> 60

# CPU alta: 2 procesos al 100% por 10 minutos (t3.micro tiene 2 vCPU)
ssh -i ~/.ssh/to-do-list-api ubuntu@<IP> "for i in 1 2; do timeout 600 yes > /dev/null & done"

# Errores de BD, tasa de errores y latencia: detiene RDS, genera tráfico, espera las alarmas y la vuelve a encender
bash scripts/probar-alarmas.sh <IP>
```
