from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from prometheus_fastapi_instrumentator import Instrumentator
import uuid
import os
import time
import random
import sys
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("payment-service")

FAILURE_MODE = os.getenv("FAILURE_MODE", "none").lower()
log.info(f"Starting payment-service with FAILURE_MODE={FAILURE_MODE}")

app = FastAPI(title="payment-service")
Instrumentator().instrument(app).expose(app)


class ChargeRequest(BaseModel):
    user_id: str
    amount: float


class ChargeResponse(BaseModel):
    transaction_id: str
    status: str
    amount: float


@app.get("/health")
def health():
    # health stays healthy even in failure modes — except crash_loop
    return {"status": "ok"}


@app.post("/charge", response_model=ChargeResponse)
def charge(req: ChargeRequest):
    # Apply failure mode
    if FAILURE_MODE == "slow":
        delay = random.uniform(3.0, 5.0)
        log.warning(f"FAILURE_MODE=slow, sleeping {delay:.2f}s")
        time.sleep(delay)

    elif FAILURE_MODE == "errors":
        if random.random() < 0.30:
            log.error(f"FAILURE_MODE=errors, returning 500 for user={req.user_id}")
            raise HTTPException(status_code=500, detail="Simulated internal error")

    elif FAILURE_MODE == "crash_loop":
        log.critical(f"FAILURE_MODE=crash_loop, exiting on charge request")
        sys.exit(1)

    tx_id = str(uuid.uuid4())
    log.info(f"Processing charge: user={req.user_id} amount={req.amount} tx={tx_id}")
    return ChargeResponse(transaction_id=tx_id, status="success", amount=req.amount)


@app.get("/")
def root():
    return {
        "service": "payment-service",
        "version": os.getenv("APP_VERSION", "v0.3.0"),
        "failure_mode": FAILURE_MODE,
    }
