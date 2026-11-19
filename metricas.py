"""Métricas personalizadas de la app en Amazon CloudWatch (boto3 put_metric_data).

En lugar de llamar a CloudWatch en cada request (lento y con muchas llamadas a la API),
las métricas se acumulan en memoria y un hilo en segundo plano las envía una vez por minuto:
  - Contadores (Requests, Errores5xx, DBErrors): se envía la suma del minuto. Siempre se
    mandan, aunque valgan 0, para que las gráficas no tengan huecos.
  - Latencia: se envían estadísticas del minuto (SampleCount, Sum, Minimum, Maximum),
    así CloudWatch puede calcular promedio y máximo.

La EC2 tiene permiso de publicar métricas gracias a su IAM role (LabInstanceProfile -> LabRole).
"""
import logging
import threading
import time
from collections import defaultdict

log = logging.getLogger(__name__)

CONTADORES_BASE = ("Requests", "Errores5xx", "DBErrors")


class Metricas:
    def __init__(self, namespace, region, intervalo_segundos=60):
        self.namespace = namespace
        self.region = region
        self.intervalo = intervalo_segundos
        self._lock = threading.Lock()
        self._contadores = defaultdict(float)
        self._latencias_ms = []
        self._hilo = None

    # ---------- Registrar (lo llama la app en cada request) ----------
    def contar(self, nombre, valor=1):
        with self._lock:
            self._contadores[nombre] += valor

    def latencia(self, milisegundos):
        with self._lock:
            self._latencias_ms.append(milisegundos)

    # ---------- Enviar a CloudWatch ----------
    def tomar_datos(self):
        """Regresa el MetricData acumulado desde el último envío y reinicia los acumuladores."""
        with self._lock:
            contadores, self._contadores = self._contadores, defaultdict(float)
            latencias, self._latencias_ms = self._latencias_ms, []

        datos = [
            {"MetricName": nombre, "Value": contadores.get(nombre, 0.0), "Unit": "Count"}
            for nombre in sorted(set(CONTADORES_BASE) | set(contadores))
        ]
        if latencias:
            datos.append(
                {
                    "MetricName": "LatenciaMs",
                    "Unit": "Milliseconds",
                    "StatisticValues": {
                        "SampleCount": len(latencias),
                        "Sum": sum(latencias),
                        "Minimum": min(latencias),
                        "Maximum": max(latencias),
                    },
                }
            )
        return datos

    def enviar(self):
        datos = self.tomar_datos()
        try:
            import boto3

            cloudwatch = boto3.client("cloudwatch", region_name=self.region)
            cloudwatch.put_metric_data(Namespace=self.namespace, MetricData=datos)
        except Exception:
            # Si CloudWatch falla, la app sigue funcionando; solo se pierde ese minuto de métricas
            log.exception("No se pudieron enviar las métricas a CloudWatch")

    def iniciar(self):
        """Arranca el hilo que envía las métricas cada `intervalo` segundos."""
        if self._hilo is not None:
            return

        def ciclo():
            while True:
                time.sleep(self.intervalo)
                self.enviar()

        self._hilo = threading.Thread(target=ciclo, name="metricas-cloudwatch", daemon=True)
        self._hilo.start()
        log.info("Enviando métricas a CloudWatch (namespace %s) cada %ss", self.namespace, self.intervalo)
