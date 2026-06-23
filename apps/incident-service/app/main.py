from fastapi import FastAPI, Request
from prometheus_fastapi_instrumentator import Instrumentator
import os
import logging
import json

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("incident-service")

app = FastAPI(title="incident-service")
Instrumentator().instrument(app).expose(app)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def root():
    return {
        "service": "incident-service",
        "version": os.getenv("APP_VERSION", "v0.1.0"),
    }


@app.post("/webhook/alert")
async def alert_webhook(request: Request):
    """
    Receive alerts from Alertmanager.
    Alertmanager POSTs JSON with an 'alerts' array.
    """
    body = await request.json()
    alerts = body.get("alerts", [])
    log.info(f"Received {len(alerts)} alert(s) from Alertmanager")

    for alert in alerts:
        status = alert.get("status", "unknown")
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})

        log.info(
            json.dumps({
                "event": "alert_received",
                "status": status,
                "alert": labels.get("alertname", "unknown"),
                "severity": labels.get("severity", "unknown"),
                "service": labels.get("service", "unknown"),
                "summary": annotations.get("summary", ""),
                "description": annotations.get("description", ""),
                "starts_at": alert.get("startsAt"),
            })
        )

    return {"status": "ok", "received": len(alerts)}
