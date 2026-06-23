from fastapi import FastAPI, Request, HTTPException
from prometheus_fastapi_instrumentator import Instrumentator
from anthropic import Anthropic
import httpx
import os
import logging
import json
import asyncio
from datetime import datetime, timedelta

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("incident-service")

# Config from environment
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
SLACK_WEBHOOK_URL = os.getenv("SLACK_WEBHOOK_URL", "")
PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090")
LOKI_URL = os.getenv("LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100")
CLAUDE_MODEL = os.getenv("CLAUDE_MODEL", "claude-haiku-4-5-20251001")

if not ANTHROPIC_API_KEY:
    log.warning("ANTHROPIC_API_KEY not set — AI analysis will be skipped")
if not SLACK_WEBHOOK_URL:
    log.warning("SLACK_WEBHOOK_URL not set — Slack posts will be skipped")

claude = Anthropic(api_key=ANTHROPIC_API_KEY) if ANTHROPIC_API_KEY else None

app = FastAPI(title="incident-service")
Instrumentator().instrument(app).expose(app)

# Dedup cache (in-memory, fine for demo): key=alert+service+minute → response
_recent_incidents = {}


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def root():
    return {"service": "incident-service", "version": os.getenv("APP_VERSION", "v0.2.0")}


async def query_prometheus(client: httpx.AsyncClient, service: str) -> dict:
    """Query Prometheus for recent metrics about the failing service."""
    queries = {
        "error_rate_5m": f'sum(rate(http_requests_total{{job="{service}",status=~"5.."}}[5m])) / sum(rate(http_requests_total{{job="{service}"}}[5m]))',
        "request_rate_5m": f'sum(rate(http_requests_total{{job="{service}"}}[5m]))',
        "p95_latency_5m": f'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{{job="{service}"}}[5m])))',
    }
    results = {}
    for name, query in queries.items():
        try:
            r = await client.get(f"{PROMETHEUS_URL}/api/v1/query", params={"query": query}, timeout=5.0)
            data = r.json()
            if data.get("status") == "success" and data["data"]["result"]:
                val = data["data"]["result"][0].get("value", [None, None])[1]
                results[name] = float(val) if val is not None else None
            else:
                results[name] = None
        except Exception as e:
            log.warning(f"Prometheus query {name} failed: {e}")
            results[name] = None
    return results


async def query_loki(client: httpx.AsyncClient, service: str) -> list:
    """Get last 20 error/warn log lines from the service in the last 5 min."""
    try:
        end = datetime.utcnow()
        start = end - timedelta(minutes=5)
        query = f'{{app="{service}"}} |~ "(?i)error|warn|fail|exception"'
        r = await client.get(
            f"{LOKI_URL}/loki/api/v1/query_range",
            params={
                "query": query,
                "start": int(start.timestamp() * 1e9),
                "end": int(end.timestamp() * 1e9),
                "limit": 20,
                "direction": "backward",
            },
            timeout=5.0,
        )
        data = r.json()
        lines = []
        if data.get("status") == "success":
            for stream in data["data"].get("result", []):
                for ts, line in stream.get("values", []):
                    lines.append(line.strip())
        return lines[:20]
    except Exception as e:
        log.warning(f"Loki query failed: {e}")
        return []


def build_prompt(alert: dict, prom_metrics: dict, log_lines: list) -> str:
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})

    parts = [
        "You are an SRE analyzing a live production incident on a Kubernetes cluster. Be concise and specific.",
        "",
        f"Alert: {labels.get('alertname', 'unknown')}",
        f"Service: {labels.get('service', 'unknown')}",
        f"Severity: {labels.get('severity', 'unknown')}",
        f"Status: {alert.get('status', 'unknown')}",
        f"Started at: {alert.get('startsAt', 'unknown')}",
        f"Summary: {annotations.get('summary', '')}",
        f"Description: {annotations.get('description', '')}",
        "",
        "Recent metrics (last 5 minutes):",
    ]

    for name, val in prom_metrics.items():
        if val is None:
            parts.append(f"  - {name}: no data")
        else:
            parts.append(f"  - {name}: {val:.4f}")

    parts.append("")
    parts.append("Recent error/warn log lines (last 5 min, up to 20):")
    if log_lines:
        for line in log_lines[:20]:
            parts.append(f"  {line[:200]}")
    else:
        parts.append("  (no recent error logs found)")

    parts.append("")
    parts.append("Provide your response in this exact format:")
    parts.append("ROOT CAUSE: <one sentence>")
    parts.append("CONFIDENCE: <low|medium|high>")
    parts.append("RECOMMENDED ACTIONS:")
    parts.append("  - <action 1>")
    parts.append("  - <action 2>")

    return "\n".join(parts)


def analyze_with_claude(prompt: str) -> str:
    if not claude:
        return "AI analysis skipped (no API key configured)."
    try:
        message = claude.messages.create(
            model=CLAUDE_MODEL,
            max_tokens=500,
            messages=[{"role": "user", "content": prompt}],
        )
        return message.content[0].text
    except Exception as e:
        log.error(f"Claude API call failed: {e}")
        return f"AI analysis failed: {type(e).__name__}"


async def post_to_slack(client: httpx.AsyncClient, alert: dict, analysis: str):
    if not SLACK_WEBHOOK_URL:
        log.info("Slack webhook not configured, skipping post")
        return
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})
    severity = labels.get("severity", "unknown")
    emoji = {"critical": "🚨", "warning": "⚠️", "info": "ℹ️"}.get(severity, "📢")

    text = (
        f"{emoji} *{labels.get('alertname', 'Alert')}* — {severity}\n"
        f"*Service:* {labels.get('service', 'unknown')}\n"
        f"*Summary:* {annotations.get('summary', '')}\n\n"
        f"*AI Analysis:*\n```{analysis}```"
    )

    try:
        r = await client.post(SLACK_WEBHOOK_URL, json={"text": text}, timeout=5.0)
        if r.status_code != 200:
            log.error(f"Slack post failed: {r.status_code} {r.text}")
    except Exception as e:
        log.error(f"Slack post exception: {e}")


async def process_alert(alert: dict):
    labels = alert.get("labels", {})
    service = labels.get("service", "unknown")
    alert_name = labels.get("alertname", "unknown")
    status = alert.get("status", "")

    # Skip resolved alerts to save API costs and noise
    if status == "resolved":
        log.info(f"Skipping resolved alert: {alert_name}/{service}")
        return

    # Dedup: same alert + service within the same minute = one analysis
    minute_bucket = int(datetime.utcnow().timestamp() // 60)
    dedup_key = f"{alert_name}-{service}-{minute_bucket}"
    if dedup_key in _recent_incidents:
        log.info(f"Deduped: {dedup_key}")
        return
    _recent_incidents[dedup_key] = True

    async with httpx.AsyncClient() as client:
        prom_metrics, log_lines = await asyncio.gather(
            query_prometheus(client, service),
            query_loki(client, service),
        )

    log.info(json.dumps({
        "event": "context_gathered",
        "alert": alert_name,
        "service": service,
        "prom_metrics": prom_metrics,
        "log_line_count": len(log_lines),
    }))

    prompt = build_prompt(alert, prom_metrics, log_lines)
    analysis = analyze_with_claude(prompt)

    log.info(json.dumps({
        "event": "analysis_complete",
        "alert": alert_name,
        "service": service,
        "analysis": analysis,
    }))

    async with httpx.AsyncClient() as client:
        await post_to_slack(client, alert, analysis)


@app.post("/webhook/alert")
async def alert_webhook(request: Request):
    body = await request.json()
    alerts = body.get("alerts", [])
    log.info(f"Received {len(alerts)} alert(s) from Alertmanager")

    async def run_all():
        await asyncio.gather(
            *(process_alert(a) for a in alerts),
            return_exceptions=True,
        )

    asyncio.create_task(run_all())

    return {"status": "ok", "received": len(alerts)}