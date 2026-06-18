from fastapi import FastAPI
from pydantic import BaseModel
import uuid
import os
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("payment-service")

app = FastAPI(title="payment-service")

class ChargeRequest(BaseModel):
    user_id: str
    amount: float

class ChargeResponse(BaseModel):
    transaction_id: str
    status: str
    amount: float

@app.get("/health")
def health():
    return {"status": "ok"}

@app.post("/charge", response_model=ChargeResponse)
def charge(req: ChargeRequest):
    tx_id = str(uuid.uuid4())
    log.info(f"Processing charge: user={req.user_id} amount={req.amount} tx={tx_id}")
    return ChargeResponse(transaction_id=tx_id, status="success", amount=req.amount)

@app.get("/")
def root():
    return {"service": "payment-service", "version": os.getenv("APP_VERSION", "v0.1.0")}
