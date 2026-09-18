#!/usr/bin/env python3
"""Alertmanager webhook receiver: for each firing log alert, re-fetches the
matching log lines from VictoriaLogs, asks the local Ollama model for a
diagnosis + action plan, and emails the result via the in-cluster Stalwart
SMTP listener. Runs alongside Alertmanager's existing plain-text email
receiver (not instead of it) — see modules/logging's ai_enrichment_webhook_url.

Stdlib only, deliberately: this runs on a generic python image with the
script mounted from a ConfigMap, no image build/registry needed.
"""

import json
import os
import re
import smtplib
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from email.mime.text import MIMEText
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VICTORIALOGS_URL = os.environ.get("VICTORIALOGS_URL", "http://victorialogs.monitoring.svc.cluster.local:9428")
K8S_API_URL = os.environ.get("K8S_API_URL", "https://kubernetes.default.svc")
K8S_TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
K8S_CA_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama.platform.svc.cluster.local:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "gemma4:26b-a4b-q3km")
SMTP_HOST = os.environ.get("SMTP_HOST", "stalwart-smtp.mail.svc.cluster.local")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "25"))
SMTP_HELLO = os.environ.get("SMTP_HELLO", "alert-llm-enricher.ipsupport.us")
SMTP_FROM = os.environ.get("SMTP_FROM", "ai-alerts@ipsupport.us")
ALERT_EMAIL_TO = os.environ["ALERT_EMAIL_TO"]
LOG_CONTEXT_LINES = int(os.environ.get("LOG_CONTEXT_LINES", "100"))
PORT = int(os.environ.get("PORT", "8080"))


def strip_aggregation(query: str) -> str:
    """Drop a query's trailing `| rename ... | stats ... | filter ...` tail,
    leaving the raw time-window + keyword filter that matches individual log
    lines instead of a pre-aggregated count."""
    parts = re.split(r"\|\s*(rename|stats)\b", query, maxsplit=1)
    return parts[0].strip()


def scope_to_source(query: str, labels: dict) -> str:
    """Best-effort narrowing to the specific namespace/pod this alert
    instance is about, when the rule's grouping produced those labels
    (the _default_alert_rules convention: src_namespace/src_pod). Rules that
    don't group by pod (e.g. the sipmesh-style rules) won't have these
    labels — the base query alone is used as-is in that case."""
    extra = []
    if labels.get("src_namespace"):
        extra.append(f'kubernetes.pod_namespace:"{labels["src_namespace"]}"')
    if labels.get("src_pod"):
        extra.append(f'kubernetes.pod_name:"{labels["src_pod"]}"')
    if not extra:
        return query
    return f"{query} {' '.join(extra)}"


def query_victorialogs(query: str, limit: int) -> list[str]:
    url = f"{VICTORIALOGS_URL}/select/logsql/query?" + urllib.parse.urlencode({"query": query, "limit": limit})
    with urllib.request.urlopen(url, timeout=15) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
    lines = []
    for line in raw.strip().splitlines():
        if not line:
            continue
        try:
            rec = json.loads(line)
            lines.append(rec.get("_msg", line))
        except json.JSONDecodeError:
            lines.append(line)
    return lines


def _k8s_get(path: str) -> dict:
    with open(K8S_TOKEN_FILE) as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=K8S_CA_FILE)
    req = urllib.request.Request(f"{K8S_API_URL}{path}", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
        return json.loads(resp.read())


def query_pod_status(namespace: str, name: str) -> str:
    """Log text structurally cannot carry a kernel OOM-kill: a SIGKILL'd
    process gets no chance to print its own death. The reason/exit-code for
    that (and for CrashLoopBackOff etc.) lives only in the pod's status,
    never in stdout — confirmed live against a real OOM-killed test pod
    whose own logs had no "OOMKilled"/"out of memory" text anywhere."""
    try:
        pod = _k8s_get(f"/api/v1/namespaces/{namespace}/pods/{name}")
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
        return f"(не удалось получить статус пода: {e})"

    lines = []
    for cs in pod.get("status", {}).get("containerStatuses", []):
        cname = cs.get("name")
        for label, state in (("текущее", cs.get("state", {})), ("предыдущее", cs.get("lastState", {}))):
            for kind, info in state.items():
                if kind == "terminated":
                    lines.append(
                        f"{cname} ({label}): terminated, reason={info.get('reason')}, exitCode={info.get('exitCode')}"
                    )
                elif kind == "waiting":
                    lines.append(f"{cname} ({label}): waiting, reason={info.get('reason')}")
    return "\n".join(lines) if lines else "(нет данных о статусе контейнеров)"


def query_pod_events(namespace: str, name: str) -> str:
    try:
        data = _k8s_get(
            f"/api/v1/namespaces/{namespace}/events?"
            + urllib.parse.urlencode({"fieldSelector": f"involvedObject.name={name}"})
        )
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
        return f"(не удалось получить события: {e})"

    events = sorted(data.get("items", []), key=lambda e: e.get("lastTimestamp") or "", reverse=True)
    lines = [f"{e.get('reason')}: {e.get('message')}" for e in events[:10] if e.get("type") == "Warning"]
    return "\n".join(lines) if lines else "(нет предупреждающих событий)"


def ask_ollama(alertname: str, summary: str, log_lines: list[str], k8s_context: str) -> str:
    log_excerpt = "\n".join(log_lines[:LOG_CONTEXT_LINES]) if log_lines else "(нет строк лога — запрос контекста не вернул совпадений)"
    k8s_block = f"\nСтатус пода и события Kubernetes:\n{k8s_context}\n" if k8s_context else ""
    prompt = (
        f"Сработал алерт мониторинга кластера: {alertname}\n"
        f"Описание: {summary}\n"
        f"{k8s_block}\n"
        f"Соответствующие строки логов:\n{log_excerpt}\n\n"
        "Кратко (3-6 предложений) объясни вероятную причину произошедшего и дай "
        "конкретный план действий (2-4 шага) — что оператору проверить или сделать "
        "в первую очередь. Пиши по-русски, по делу, без общих фраз и без воды."
    )
    payload = json.dumps(
        {
            "model": OLLAMA_MODEL,
            "prompt": prompt,
            "stream": False,
            # gemma4 always produces a <think>...</think> block unless told
            # not to — confirmed live that num_predict alone doesn't help,
            # the model burns the whole budget on the thinking block and
            # "response" comes back empty before ever reaching an answer.
            # think:false is Ollama's documented way to suppress it (the
            # model can't be asked via prompt text — it's baked in at
            # training time, not a runtime toggle any instruction changes).
            "think": False,
            "options": {"num_predict": 400},
        }
    ).encode()
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/generate", data=payload, headers={"Content-Type": "application/json"}
    )
    # This is the SAME shared Ollama instance OpenWebUI chat uses, with only
    # OLLAMA_NUM_PARALLEL=2 slots — a live chat reply (which does NOT get
    # think:false, so it can run long) can occupy both, leaving this request
    # queued rather than actively generating. A short timeout would then read
    # as "LLM unavailable" for a request that just hadn't reached the front
    # of the queue yet. Generation itself is fast (~15-16 t/s on this model);
    # the slack here is for queueing, not for the model being slow.
    with urllib.request.urlopen(req, timeout=300) as resp:
        data = json.loads(resp.read())
    return data.get("response", "").strip()


def send_email(subject: str, body: str) -> None:
    msg = MIMEText(body, "plain", "utf-8")
    msg["Subject"] = subject
    msg["From"] = SMTP_FROM
    msg["To"] = ALERT_EMAIL_TO
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, local_hostname=SMTP_HELLO, timeout=15) as s:
        s.send_message(msg)


def handle_alert(alert: dict) -> None:
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})
    alertname = labels.get("alertname", "unknown")
    summary = annotations.get("summary", "")
    raw_query = annotations.get("logsql_query", "")

    log_lines: list[str] = []
    if raw_query:
        query = scope_to_source(strip_aggregation(raw_query), labels)
        try:
            log_lines = query_victorialogs(query, LOG_CONTEXT_LINES)
        except (urllib.error.URLError, TimeoutError) as e:
            print(f"victorialogs query failed for {alertname}: {e}", file=sys.stderr)

    k8s_context = ""
    src_namespace, src_pod = labels.get("src_namespace"), labels.get("src_pod")
    if src_namespace and src_pod:
        status = query_pod_status(src_namespace, src_pod)
        events = query_pod_events(src_namespace, src_pod)
        k8s_context = f"Статус контейнеров:\n{status}\n\nПоследние Warning-события:\n{events}"

    try:
        diagnosis = ask_ollama(alertname, summary, log_lines, k8s_context)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        print(f"ollama request failed for {alertname}: {e}", file=sys.stderr)
        diagnosis = f"(LLM-разбор недоступен: {e})"

    subject = f"[AI-разбор] {alertname}: {summary}"[:200]
    k8s_section = f"\n--- Статус пода / события Kubernetes ---\n{k8s_context}\n" if k8s_context else ""
    body = (
        f"{summary}\n\n"
        f"--- Разбор от локальной LLM ({OLLAMA_MODEL}) ---\n{diagnosis}\n"
        f"{k8s_section}\n"
        f"--- Контекст логов ({len(log_lines)} строк, показаны первые 30) ---\n"
        + "\n".join(log_lines[:30])
    )
    send_email(subject, body)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != "/webhook":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        # Ack immediately: Alertmanager's webhook timeout is short (default
        # 10s) and Ollama generation alone can take longer than that — an
        # ack-after-processing response risks Alertmanager treating this as
        # a failed delivery and retrying, duplicating the enrichment email.
        # Content-Length is required for this to actually work: without it
        # the client has no way to know the body is complete except by the
        # connection closing, which do_POST doesn't do until handle_alert()
        # below has finished — silently defeating the "ack immediately"
        # intent (confirmed live: a client blocked on resp.read() for the
        # full processing time despite the ack bytes being written early).
        ack = b"ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(ack)))
        self.end_headers()
        self.wfile.write(ack)
        try:
            payload = json.loads(body)
        except json.JSONDecodeError as e:
            print(f"bad webhook payload: {e}", file=sys.stderr)
            return
        for alert in payload.get("alerts", []):
            if alert.get("status") != "firing":
                continue
            try:
                handle_alert(alert)
            except Exception as e:  # noqa: BLE001 - one bad alert must not affect the next
                print(f"enrichment failed for {alert.get('labels', {}).get('alertname')}: {e}", file=sys.stderr)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), file=sys.stderr)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"alert-llm-enricher listening on :{PORT}", file=sys.stderr)
    server.serve_forever()
