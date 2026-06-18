import httpx
import time
import random
import os
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("load-generator")

ORDER_URL = os.getenv("ORDER_SERVICE_URL", "http://order-service.default.svc.cluster.local")
RATE_PER_SEC = float(os.getenv("RATE_PER_SEC", "5"))

USERS = [f"user-{i}" for i in range(100)]
ITEMS_POOL = ["sku-1", "sku-2", "sku-3", "sku-4", "sku-5"]

def make_request(client: httpx.Client):
    payload = {
        "user_id": random.choice(USERS),
        "items": random.sample(ITEMS_POOL, k=random.randint(1, 3)),
        "total": round(random.uniform(5, 200), 2),
    }
    try:
        r = client.post(f"{ORDER_URL}/orders", json=payload, timeout=5.0)
        log.info(f"POST /orders -> {r.status_code}")
    except Exception as e:
        log.warning(f"Request failed: {e}")

def main():
    sleep_between = 1.0 / RATE_PER_SEC
    log.info(f"Targeting {ORDER_URL} at {RATE_PER_SEC} req/sec")
    with httpx.Client() as client:
        while True:
            make_request(client)
            time.sleep(sleep_between)

if __name__ == "__main__":
    main()
