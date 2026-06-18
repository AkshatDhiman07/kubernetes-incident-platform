from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import List
import httpx
import os
import logging
import uuid

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("order-service")

PAYMENT_URL = os.getenv("PAYMENT_SERVICE_URL", "http://payment-service.default.svc.cluster.local")

app = FastAPI(title="order-service")

class OrderRequest(BaseModel):
    user_id: str
    items: List[str]
    total: float

class OrderResponse(BaseModel):
    order_id: str
    transaction_id: str
    status: str

@app.get("/health")
def health():
    return {"status": "ok"}

@app.post("/orders", response_model=OrderResponse)
def create_order(req: OrderRequest):
    order_id = str(uuid.uuid4())
    log.info(f"Creating order: user={req.user_id} total={req.total} order={order_id}")
    try:
        with httpx.Client(timeout=3.0) as client:
            r = client.post(
                f"{PAYMENT_URL}/charge",
                json={"user_id": req.user_id, "amount": req.total},
            )
            r.raise_for_status()
            data = r.json()
        return OrderResponse(order_id=order_id, transaction_id=data["transaction_id"], status="completed")
    except httpx.HTTPError as e:
        log.error(f"Payment call failed: {e}")
        raise HTTPException(status_code=502, detail="Payment service unavailable")

@app.get("/")
def root():
    return {"service": "order-service", "version": os.getenv("APP_VERSION", "v0.1.0")}
