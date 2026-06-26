from fastapi import FastAPI, Request
from prometheus_fastapi_instrumentator import Instrumentator
from anthropic import Anthropic
from kubernetes import client as k8s_client, config as k8s_config
import httpx
import os
import logging
import json
import asyncio
from datetime import datetime, timedelta, timezone

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("incident-service")

ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
SLACK_WEBHOOK_URL = os.getenv("SLACK_WEBHOOK_URL", "")
PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090")
LOKI_URL = os.getenv("LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100")
CLAUDE_MODEL = os.getenv("CLAUDE_MODEL", "claude-haiku-4-5-20251001")

if not ANTHROPIC_API_KEY:
    log.warning("ANTHROPIC_API_KEY not set")
if not SLACK_WEBHOOK_URL:
    log.warning("SLACK_WEBHOOK_URL not set")

claude = Anthropic(api_key=ANTHROPIC_API_KEY) if ANTHROPIC_API_KEY else None

# Load k8s config from inside the pod
try:
    k8s_config.load_incluster_config()
    core_v1 = k8s_client.CoreV1Api()
    apps_v1 = k8s_client.AppsV1Api()
    custom = k8s_client.CustomObjectsApi()
    log.info("K8s client initialized (incluster)")
except Exception as e:
    log.warning(f"K8s client init failed: {e}; running without K8s context")
    core_v1 = None
    apps_v1 = None
    custom = None

app = FastAPI(title="incident-service")
Instrumentator().instrument(app).expose(app)

_recent_incidents = {}


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def root():
    return {"service": "incident-service", "version": os.getenv("APP_VERSION", "v0.3.0")}


async def query_prometheus(client: httpx.AsyncClient, service: str) -> dict:
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
    try:
        end = datetime.now(timezone.utc)
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


def query_k8s_events(service: str) -> list:
    """Get recent K8s events for the affected service's pods."""
    if not core_v1:
        return []
    try:
        events = core_v1.list_namespaced_event(
            namespace="default",
            field_selector=f"involvedObject.name~={service}",
            limit=10,
        )
        # field_selector doesn't support regex everywhere; fallback to listing all and filtering
        return [
            {
                "type": e.type,
                "reason": e.reason,
                "object": f"{e.involved_object.kind}/{e.involved_object.name}",
                "message": e.message,
                "time": e.last_timestamp.isoformat() if e.last_timestamp else None,
            }
            for e in events.items
            if service in (e.involved_object.name or "")
        ][:10]
    except Exception as e:
        # Try fallback listing all events
        try:
            all_events = core_v1.list_namespaced_event(namespace="default", limit=100)
            return [
                {
                    "type": e.type,
                    "reason": e.reason,
                    "object": f"{e.involved_object.kind}/{e.involved_object.name}",
                    "message": e.message,
                    "time": e.last_timestamp.isoformat() if e.last_timestamp else None,
                }
                for e in all_events.items
                if service in (e.involved_object.name or "")
            ][-10:]
        except Exception as ee:
            log.warning(f"K8s events query failed: {ee}")
            return []


def query_deployment_env(service: str) -> dict:
    """Get current env vars of the service's deployment."""
    if not apps_v1:
        return {}
    try:
        deploy = apps_v1.read_namespaced_deployment(name=service, namespace="default")
        envs = {}
        for container in deploy.spec.template.spec.containers:
            for env_var in (container.env or []):
                if env_var.value:
                    envs[env_var.name] = env_var.value
                elif env_var.value_from:
                    envs[env_var.name] = "<from secret/configmap>"
        return envs
    except Exception as e:
        log.warning(f"Deployment env query failed: {e}")
        return {}


def query_argocd_status(service: str) -> dict:
    """Get the ArgoCD Application status and last sync time."""
    if not custom:
        return {}
    try:
        app_obj = custom.get_namespaced_custom_object(
            group="argoproj.io",
            version="v1alpha1",
            namespace="argocd",
            plural="applications",
            name=service,
        )
        status = app_obj.get("status", {})
        history = status.get("history", [])
        last_deploy = history[-1] if history else {}
        return {
            "sync_status": status.get("sync", {}).get("status"),
            "health_status": status.get("health", {}).get("status"),
            "last_deployed_at": last_deploy.get("deployedAt"),
            "last_revision": (last_deploy.get("revision") or "")[:8],
        }
    except Exception as e:
        log.warning(f"ArgoCD status query failed: {e}")
        return {}


def build_prompt(alert: dict, prom: dict, logs: list, events: list, env: dict, argocd: dict) -> str:
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})

    parts = [
        "You are an SRE diagnosing a live production incident on Kubernetes. Be specific and evidence-based.",
        "",
        "=== ALERT ===",
        f"Name: {labels.get('alertname', 'unknown')}",
        f"Service: {labels.get('service', 'unknown')}",
        f"Severity: {labels.get('severity', 'unknown')}",
        f"Status: {alert.get('status', 'unknown')}",
        f"Started: {alert.get('startsAt', 'unknown')}",
        f"Summary: {annotations.get('summary', '')}",
        f"Description: {annotations.get('description', '')}",
        "",
        "=== METRICS (last 5 min) ===",
    ]
    for k, v in prom.items():
        parts.append(f"  {k}: {'no data' if v is None else f'{v:.4f}'}")

    parts.append("")
    parts.append("=== DEPLOYMENT ENV VARS ===")
    if env:
        for k, v in env.items():
            parts.append(f"  {k}={v}")
    else:
        parts.append("  (no env data available)")

    parts.append("")
    parts.append("=== ARGOCD STATUS ===")
    if argocd:
        for k, v in argocd.items():
            parts.append(f"  {k}: {v}")
    else:
        parts.append("  (no ArgoCD data)")

    parts.append("")
    parts.append("=== KUBERNETES EVENTS ===")
    if events:
        for e in events[:5]:
            parts.append(f"  [{e.get('type')}] {e.get('reason')} on {e.get('object')}: {e.get('message', '')[:120]}")
    else:
        parts.append("  (no recent events)")

    parts.append("")
    parts.append("=== ERROR/WARN LOGS (last 5 min, up to 20) ===")
    if logs:
        for line in logs[:20]:
            parts.append(f"  {line[:200]}")
    else:
        parts.append("  (no recent error logs)")

    parts.append("")
    parts.append("=== REQUIRED OUTPUT FORMAT ===")
    parts.append("Provide your response in exactly this format. The EVIDENCE field must cite specific items from the context above.")
    parts.append("")
    parts.append("ROOT CAUSE: <one sentence describing the most likely cause>")
    parts.append("EVIDENCE: <which specific metric/log/event/env-var supports this conclusion>")
    parts.append("CONFIDENCE: <low|medium|high>")
    parts.append("WHY THIS CONFIDENCE: <one sentence justification>")
    parts.append("PROPOSED REMEDIATION:")
    parts.append("  <a specific kubectl command from this allowlist:>")
    parts.append("    - kubectl rollout restart deployment/<name> -n default")
    parts.append("    - kubectl scale deployment/<name> --replicas=<N> -n default")
    parts.append("    - kubectl delete pod -l app=<name> -n default")
    parts.append("  <or write 'NO SAFE ACTION' if none of these would help>")
    parts.append("NEXT STEPS FOR HUMAN: <what the on-call should investigate further>")

    return "\n".join(parts)


def analyze_with_claude(prompt: str) -> str:
    if not claude:
        return "AI analysis skipped (no API key configured)."
    try:
        message = claude.messages.create(
            model=CLAUDE_MODEL,
            max_tokens=700,
            messages=[{"role": "user", "content": prompt}],
        )
        return message.content[0].text
    except Exception as e:
        log.error(f"Claude API call failed: {e}")
        return f"AI analysis failed: {type(e).__name__}: {e}"


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
        f"*Service:* `{labels.get('service', 'unknown')}`\n"
        f"*Summary:* {annotations.get('summary', '')}\n\n"
        f"*AI Analysis:*\n```{analysis}```\n"
        f"_This is an AI-generated suggestion. Review evidence before running any commands._"
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

    if status == "resolved":
        log.info(f"Skipping resolved alert: {alert_name}/{service}")
        return

    minute_bucket = int(datetime.now(timezone.utc).timestamp() // 60)
    dedup_key = f"{alert_name}-{service}-{minute_bucket}"
    if dedup_key in _recent_incidents:
        log.info(f"Deduped: {dedup_key}")
        return
    _recent_incidents[dedup_key] = True

    async with httpx.AsyncClient() as client:
        prom, logs = await asyncio.gather(
            query_prometheus(client, service),
            query_loki(client, service),
        )

    # K8s queries are sync (the client lib isn't async-native); run in executor
    loop = asyncio.get_event_loop()
    events = await loop.run_in_executor(None, query_k8s_events, service)
    env = await loop.run_in_executor(None, query_deployment_env, service)
    argocd = await loop.run_in_executor(None, query_argocd_status, service)

    log.info(json.dumps({
        "event": "context_gathered",
        "alert": alert_name,
        "service": service,
        "prom_metrics": prom,
        "log_line_count": len(logs),
        "event_count": len(events),
        "env_var_count": len(env),
        "argocd_synced": argocd.get("sync_status"),
    }))

    prompt = build_prompt(alert, prom, logs, events, env, argocd)
    analysis = analyze_with_claude(prompt)

    log.info(json.dumps({
        "event": "analysis_complete",
        "alert": alert_name,
        "service": service,
        "analysis": analysis[:500],
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
