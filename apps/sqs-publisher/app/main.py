"""
sqs-publisher: receives HTTP webhooks from Alertmanager and enqueues to SQS.
Single responsibility — translate HTTP into queue message. No business logic.
"""
from fastapi import FastAPI, Request, HTTPException
from prometheus_fastapi_instrumentator import Instrumentator
import boto3
import os
import logging
import json

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("sqs-publisher")

SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

if not SQS_QUEUE_URL:
    log.warning("SQS_QUEUE_URL not set — publisher will fail on every webhook")

sqs = boto3.client("sqs", region_name=AWS_REGION)

app = FastAPI(title="sqs-publisher")
Instrumentator().instrument(app).expose(app)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def root():
    return {
        "service": "sqs-publisher",
        "version": os.getenv("APP_VERSION", "v0.1.0"),
        "queue_url": SQS_QUEUE_URL[-60:] if SQS_QUEUE_URL else "not set",
    }


@app.post("/webhook/alert")
async def alert_webhook(request: Request):
    body = await request.json()
    alerts = body.get("alerts", [])
    log.info(f"Received {len(alerts)} alert(s) from Alertmanager")

    if not SQS_QUEUE_URL:
        raise HTTPException(status_code=500, detail="SQS_QUEUE_URL not configured")

    try:
        response = sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=json.dumps(body),
            MessageAttributes={
                "alert_count": {
                    "DataType": "Number",
                    "StringValue": str(len(alerts)),
                },
            },
        )
        message_id = response.get("MessageId", "")
        log.info(json.dumps({
            "event": "alert_enqueued",
            "message_id": message_id,
            "alert_count": len(alerts),
        }))
        return {"status": "ok", "message_id": message_id, "alerts_enqueued": len(alerts)}
    except Exception as e:
        log.error(f"SQS send_message failed: {type(e).__name__}: {e}")
        raise HTTPException(status_code=500, detail=f"SQS publish failed: {e}")
