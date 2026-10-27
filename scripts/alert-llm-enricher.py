#!/usr/bin/env python3
"""Alertmanager webhook receiver: for each notification of firing log alerts
(one Alertmanager group), gathers what an on-call engineer would look at —
the log lines around each match (VictoriaLogs), the pod, its owner and node
(Kubernetes API), every other alert firing in the cluster (Alertmanager API)
and the operator's runbook — asks a local LLM (the shared Ollama, or an
OpenAI-compatible server) for one diagnosis of the whole group, and sends it
by e-mail through the in-cluster Stalwart SMTP listener and, when configured,
as an ntfy push. Runs alongside Alertmanager's existing plain-text email
receiver (not instead of it) — see modules/logging's ai_enrichment_webhook_url.

Stdlib only, deliberately: this runs on a generic python image with the
script mounted from a ConfigMap, no image build/registry needed.
"""

import html
import io
import json
import os
import re
import smtplib
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone
from email.mime.application import MIMEApplication
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VICTORIALOGS_URL = os.environ.get("VICTORIALOGS_URL", "http://victorialogs.monitoring.svc.cluster.local:9428")
ALERTMANAGER_URL = os.environ.get(
    "ALERTMANAGER_URL", "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093"
).rstrip("/")
K8S_API_URL = os.environ.get("K8S_API_URL", "https://kubernetes.default.svc")
K8S_TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
K8S_CA_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
# "ollama" (Ollama /api/generate) or "openai" (OpenAI-compatible
# /chat/completions; LLM_URL then includes the /v1 prefix).
LLM_API = os.environ.get("LLM_API", "ollama")
LLM_URL = (os.environ.get("LLM_URL") or "http://ollama.platform.svc.cluster.local:11434").rstrip("/")
LLM_MODEL = os.environ["LLM_MODEL"]
LLM_MAX_TOKENS = int(os.environ.get("LLM_MAX_TOKENS", "900"))
# The prompt is cut to this many characters (oldest log lines go first). Keep
# it well inside the model's context window, which also has to hold the answer.
PROMPT_CHAR_BUDGET = int(os.environ.get("PROMPT_CHAR_BUDGET", "16000"))
DIAGNOSIS_LANGUAGE = os.environ.get("DIAGNOSIS_LANGUAGE", "English")
RUNBOOK_FILE = os.environ.get("RUNBOOK_FILE", "/app/runbook.md")
NODE_POOL_LABEL = os.environ.get("NODE_POOL_LABEL", "node-pool")
# ntfy topic URL (any query string, e.g. ?template=alertmanager, is ignored);
# empty = e-mail only.
PUSH_URL = os.environ.get("PUSH_URL", "")
PUSH_TOPIC = urllib.parse.urlsplit(PUSH_URL).path.strip("/") if PUSH_URL else ""
SMTP_HOST = os.environ.get("SMTP_HOST", "stalwart-smtp.mail.svc.cluster.local")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "25"))
SMTP_HELLO = os.environ["SMTP_HELLO"]
SMTP_FROM = os.environ["SMTP_FROM"]
ALERT_EMAIL_TO = os.environ["ALERT_EMAIL_TO"]
# Log lines kept per alert after repeats are collapsed, and the lines of
# surrounding context fetched around every match.
LOG_CONTEXT_LINES = int(os.environ.get("LOG_CONTEXT_LINES", "80"))
LOG_SURROUNDING_LINES = int(os.environ.get("LOG_SURROUNDING_LINES", "5"))
PORT = int(os.environ.get("PORT", "8080"))
# Security digest (trivy-operator VulnerabilityReports): seconds between
# checks, 0 = off. A digest goes out only when something changed; images that
# could be updated but weren't are reminded of after SECURITY_DIGEST_REMINDER_SECONDS.
SECURITY_DIGEST_INTERVAL = int(os.environ.get("SECURITY_DIGEST_INTERVAL_SECONDS", "0"))
SECURITY_DIGEST_REMINDER = int(os.environ.get("SECURITY_DIGEST_REMINDER_SECONDS", str(7 * 86400)))
SECURITY_SEVERITIES = {
    s.strip().upper() for s in os.environ.get("SECURITY_DIGEST_SEVERITIES", "Critical").split(",") if s.strip()
}
# ConfigMap (in POD_NAMESPACE) holding what the last digest reported.
SECURITY_STATE_CONFIGMAP = os.environ.get("SECURITY_STATE_CONFIGMAP", "")
POD_NAMESPACE = os.environ.get("POD_NAMESPACE", "")

LOG_FETCH_LIMIT = 500
MAX_LINE_CHARS = 500
# Alerts in one notification that get their own context; the rest are counted.
MAX_ALERTS = 8
# Other alerts older than this are listed as long-standing background.
FRESH_SECONDS = 2 * 3600
NOISE_ALERTS = {"Watchdog", "InfoInhibitor"}
_SEVERITY_RANK = {"none": 0, "info": 1, "warning": 2, "critical": 3}
# Labels that say nothing about the incident (routing plumbing).
SKIP_LABELS = {"alertname", "severity", "namespace", "alert_source", "prometheus", "endpoint", "service"}
PUSH_MAX_BYTES = 3500
# ntfy refuses a JSON publish over twice its 4 KiB message limit (413).
PUSH_MAX_BODY_BYTES = 8192
# A diagnosis should stick to the evidence; a low temperature keeps small
# models from inventing causes.
LLM_TEMPERATURE = 0.2
# Webhook bodies are a few KB; anything far larger is not Alertmanager.
MAX_BODY_BYTES = 1 << 20
# Groups processed at once; further notifications wait their turn instead of
# piling up LLM calls and memory.
_WORKERS = threading.BoundedSemaphore(2)
# The webhook is acknowledged before processing, so Alertmanager never
# retries it: retry the SMTP hand-off here (seconds between attempts).
SMTP_RETRY_DELAYS = (30, 120)

BASE_SYSTEM_PROMPT = """You are the on-call SRE assistant for a Kubernetes cluster. You get a group of alerts \
that fired together, the log lines and Kubernetes state behind each of them, and the other alerts firing \
in the cluster right now.

Rules:
- Base every claim on the data given. If the data does not show the cause, say so and name what to look at \
next. Never invent a cause.
- Link alerts that share a cause (same node, same time, same dependency) and say which one is most likely \
the root and which are consequences.
- Long-standing alerts are usually known background; mention one only if it plausibly relates.
- Suggest read-only checks only (kubectl get/describe/logs/top, log or metric queries). Never suggest \
commands that change anything or start pods: no delete, patch, edit, apply, restart, scale, exec, run, \
debug or cp. Changes to the cluster go through infrastructure-as-code: say what to change and where.
- Be specific and short. No filler, no generic advice.

Write the whole answer in {language}, as plain text with these four sections, each heading written in \
{language}:
1. Summary: one or two sentences on what is happening as a whole. This part is also sent as a push \
notification, so it must stand on its own.
2. Likely cause: the cause, your confidence (high, medium or low) and the evidence from the data.
3. Check first: two to four read-only steps, with commands where useful.
4. If confirmed: what to change and where."""


# Secrets that leak into log lines must not leave the cluster: the e-mail and
# the push (ntfy is a third-party service) carry log text and the model's
# answer, which may quote what it saw. Masked before the prompt is built and
# again on everything sent out. Best effort: recognised shapes only.
_SECRET_KEYS = (
    r"pass(?:word|wd|phrase)?|pwd|secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key"
    r"|client[_-]?secret|credentials?|cookie|session[_-]?id"
)


def _mask_value(match: re.Match) -> str:
    value = match.group(2)
    if value[:1] in "\"'" and value[-1:] == value[:1] and len(value) > 1:
        return f"{match.group(1)}{value[0]}***{value[0]}"
    return f"{match.group(1)}***"


_SECRET_PATTERNS = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S), "[private key]"),
    # scheme://user:password@host — the password may itself hold "/" or "@".
    (re.compile(r"(\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s:/@]*:)\S+@(?=[^\s@/]*(?:[/\s?#]|$))"), r"\1***@"),
    (re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"), r"\1 ***"),
    # password=..., "api_key": "a b", DB_PASSWORD: ..., ?access_token=..., pass=...
    (
        re.compile(
            rf"(?i)([\"']?\b[\w.-]*?(?:{_SECRET_KEYS})[\"']?\s*[:=]\s*)(\"[^\"]*\"|'[^']*'|[^\s\"'&;}}]+)"
        ),
        _mask_value,
    ),
    # --password hunter2, -token abc
    (re.compile(rf"(?i)(\s--?(?:{_SECRET_KEYS}|auth)\s+)(\S+)"), _mask_value),
    (re.compile(r"\beyJ[\w-]{5,}\.[\w-]{5,}\.[\w-]{5,}"), "***"),
    (
        re.compile(
            r"\b(?:gh[opusr]_[A-Za-z0-9]{20,}|github_pat_\w{20,}|glpat-[\w-]{20,}|sk-[A-Za-z0-9_-]{20,}"
            r"|xox[abprs]-[\w-]{10,}|AKIA[0-9A-Z]{16}|hf_[A-Za-z0-9]{20,})"
        ),
        "***",
    ),
]
# Long random-looking runs (base64 keys, random tokens): digits plus a real
# mix of upper- and lower-case letters. Hex digests, Kubernetes names and
# CamelCase identifiers ("ReplicaSet/app-7f9c6d5b8a") have few or no
# capitals and stay readable.
_TOKEN_LIKE = re.compile(r"[A-Za-z0-9+/_-]{32,}={0,2}")


def _mask_token_like(match: re.Match) -> str:
    s = match.group(0)
    upper = sum(c.isupper() for c in s)
    lower = sum(c.islower() for c in s)
    letters = upper + lower
    if re.search(r"\d", s) and letters and upper >= 0.2 * letters and lower >= 0.2 * letters:
        return "***"
    return s


def redact(text: str) -> str:
    # The push topic works like a password.
    if len(PUSH_TOPIC) >= 4:
        text = text.replace(PUSH_TOPIC, "***")
    for pattern, replacement in _SECRET_PATTERNS:
        text = pattern.sub(replacement, text)
    return _TOKEN_LIKE.sub(_mask_token_like, text)


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
    don't group by pod (e.g. rules that aggregate across pods) won't have these
    labels — the base query alone is used as-is in that case."""
    extra = []
    if labels.get("src_namespace"):
        extra.append(f'kubernetes.pod_namespace:"{labels["src_namespace"]}"')
    if labels.get("src_pod"):
        extra.append(f'kubernetes.pod_name:"{labels["src_pod"]}"')
    if not extra:
        return query
    return f"{query} {' '.join(extra)}"


def query_victorialogs(query: str, limit: int) -> list[dict]:
    url = f"{VICTORIALOGS_URL}/select/logsql/query?" + urllib.parse.urlencode({"query": query, "limit": limit})
    with urllib.request.urlopen(url, timeout=15) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
    records = []
    for line in raw.strip().splitlines():
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            records.append({"_msg": line})
    return records


_VARYING = re.compile(
    r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?"  # timestamps
    r"|\b\d{2}:\d{2}:\d{2}(?:[.,]\d+)?\b"
    r"|\b\d{1,3}(?:\.\d{1,3}){3}\b"  # IPv4
    r"|\b(?=[0-9a-fA-F-]*\d)[0-9a-fA-F-]{8,}\b"  # hex IDs, UUIDs, hashes
    r"|\b\d+(?:\.\d+)?(?:ns|us|µs|ms|s|m|h)\b"  # durations
    r"|\d{5,}"  # counters, long IDs
)


def _normalize(msg: str) -> str:
    """Key for "the same line again": timestamps, addresses, IDs and
    durations vary between repeats of one error and must not split it into
    many lines; short numbers (exit codes, ports, status codes) tell errors
    apart and are kept."""
    return _VARYING.sub("#", msg)


def compress_lines(records: list[dict], max_lines: int) -> list[str]:
    """Log records (oldest first, `---` between stream_context groups) as
    "HH:MM:SS message" lines; repeats of a line are folded into its latest
    occurrence with a count (so a recurring error stays among the newest
    lines), and only the newest max_lines survive."""
    entries: list = []
    index: dict[str, dict] = {}
    in_key = False
    for rec in records:
        raw = str(rec.get("_msg", ""))
        t = str(rec.get("_time", ""))[11:19]
        # A private key logged one line per record: hide everything between
        # its BEGIN and END lines.
        if in_key:
            in_key = not ("-----END" in raw and "PRIVATE KEY" in raw)
            continue
        if "-----BEGIN" in raw and "PRIVATE KEY" in raw and "-----END" not in raw:
            in_key = True
            raw = "[private key]"
        msg = " ".join(redact(raw).split())
        if msg == "---":
            if entries and entries[-1] != "---":
                entries.append("---")
            continue
        if len(msg) > MAX_LINE_CHARS:
            msg = msg[:MAX_LINE_CHARS] + "…"
        key = _normalize(msg)
        entry = index.get(key)
        if entry:
            entries.remove(entry)
            entry.update(count=entry["count"] + 1, last=t, msg=msg)
        else:
            entry = index[key] = {"first": t, "last": t, "msg": msg, "count": 1}
        entries.append(entry)

    lines: list[str] = []
    for e in entries:
        if e == "---":
            if lines and lines[-1] != "---":
                lines.append("---")
            continue
        line = f"{e['last']} {e['msg']}".strip()
        if e["count"] > 1:
            line += f"  [x{e['count']} since {e['first']}]"
        lines.append(line)
    while lines and lines[-1] == "---":
        lines.pop()

    if len(lines) > max_lines:
        dropped = len(lines) - max_lines
        lines = [f"({dropped} earlier lines omitted)"] + lines[-max_lines:]
    return lines


def _k8s_get(path: str) -> dict:
    with open(K8S_TOKEN_FILE) as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=K8S_CA_FILE)
    req = urllib.request.Request(f"{K8S_API_URL}{path}", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
        return json.loads(resp.read())


def _parse_time(value: str) -> datetime | None:
    if not value:
        return None
    # Alertmanager/Kubernetes timestamps: trim sub-microsecond digits, Z → +00:00.
    value = re.sub(r"(\.\d{6})\d+", r"\1", value).replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def _age(value: str, now: datetime | None = None) -> str:
    t = _parse_time(value)
    if t is None:
        return "?"
    seconds = int(((now or datetime.now(timezone.utc)) - t).total_seconds())
    if seconds < 3600:
        return f"{max(seconds // 60, 0)}m"
    if seconds < 48 * 3600:
        return f"{seconds // 3600}h"
    return f"{seconds // 86400}d"


def _state_text(state: dict) -> str:
    """Kernel OOM-kills and crash loops never reach the log text (a SIGKILL'd
    process can't print its own death); their reason and exit code exist
    only in the container state, so they are spelled out here."""
    if not state:
        return "-"
    kind, info = next(iter(state.items()))
    if kind == "terminated":
        return f"terminated(reason={info.get('reason')}, exitCode={info.get('exitCode')}, at={info.get('finishedAt')})"
    if kind == "waiting":
        return f"waiting(reason={info.get('reason')})"
    return kind


def _pod_lines(pod: dict) -> list[str]:
    meta, spec, status = pod.get("metadata", {}), pod.get("spec", {}), pod.get("status", {})
    owners = ", ".join(f"{o.get('kind')}/{o.get('name')}" for o in meta.get("ownerReferences", [])) or "-"
    lines = [
        f"Pod {meta.get('name')}: phase={status.get('phase')}, node={spec.get('nodeName', '-')}, "
        f"age={_age(meta.get('creationTimestamp', ''))}, owner={owners}"
    ]
    for cs in status.get("containerStatuses", []):
        lines.append(
            f"  container {cs.get('name')}: ready={cs.get('ready')}, restarts={cs.get('restartCount')}, "
            f"now={_state_text(cs.get('state', {}))}, previous={_state_text(cs.get('lastState', {}))}, "
            f"image={cs.get('image', '-')}"
        )
    return lines


def node_summary(name: str, nodes: dict) -> str:
    if not name:
        return ""
    if name not in nodes:
        try:
            node = _k8s_get(f"/api/v1/nodes/{name}")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                nodes[name] = f"Node {name}: not registered — powered off or removed from the cluster"
            else:
                nodes[name] = f"Node {name}: could not read (HTTP {e.code})"
            return nodes[name]
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
            nodes[name] = f"Node {name}: could not read ({e})"
            return nodes[name]
        conds = {c.get("type"): c.get("status") for c in node.get("status", {}).get("conditions", [])}
        bad = [t for t, s in conds.items() if t != "Ready" and s == "True"]
        parts = [f"Ready={conds.get('Ready', '?')}"]
        pool = node.get("metadata", {}).get("labels", {}).get(NODE_POOL_LABEL)
        if pool:
            parts.append(f"pool={pool}")
        if node.get("spec", {}).get("unschedulable"):
            parts.append("cordoned")
        if bad:
            parts.append("conditions=" + ",".join(bad))
        nodes[name] = f"Node {name}: " + ", ".join(parts)
    return nodes[name]


def query_pod_events(namespace: str, name: str) -> str:
    try:
        data = _k8s_get(
            f"/api/v1/namespaces/{namespace}/events?"
            + urllib.parse.urlencode({"fieldSelector": f"involvedObject.name={name}"})
        )
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
        return f"(could not read events: {e})"
    warnings = [e for e in data.get("items", []) if e.get("type") == "Warning"]
    warnings.sort(key=lambda e: e.get("lastTimestamp") or e.get("eventTime") or "", reverse=True)
    lines = [
        f"  {e.get('reason')} x{e.get('count', 1)} ({_age(e.get('lastTimestamp') or '')} ago): {e.get('message')}"
        for e in warnings[:10]
    ]
    return "Warning events:\n" + "\n".join(lines) if lines else "Warning events: none"


def _current_siblings(namespace: str, name: str) -> list[dict]:
    """Pods that replaced a deleted one, matched by controller rather than by
    name prefix: the same owner (ReplicaSet, StatefulSet, DaemonSet, Job) —
    `<owner>-<suffix>` — or, after a Deployment rollout, another ReplicaSet of
    the same Deployment — `<deployment>-<rs hash>-<suffix>`. Newest first."""
    items = _k8s_get(f"/api/v1/namespaces/{namespace}/pods").get("items", [])
    owner = name.rsplit("-", 1)[0]
    # Only a ReplicaSet name ends in a pod-template-hash (Kubernetes'
    # consonant/digit alphabet); "api-worker" must not widen to "api".
    is_replicaset = re.search(r"-[bcdfghjklmnpqrstvwxz2456789]{5,10}$", owner) is not None
    deployment = owner.rsplit("-", 1)[0] if is_replicaset else ""

    def owned(p: dict, same_deployment: bool) -> bool:
        for ref in p.get("metadata", {}).get("ownerReferences", []):
            ref_name = ref.get("name", "")
            if ref_name == owner:
                return True
            if same_deployment and ref.get("kind") == "ReplicaSet" and ref_name.rsplit("-", 1)[0] == deployment:
                return True
        return False

    found = [p for p in items if owned(p, bool(deployment))]
    found = [p for p in found if p.get("metadata", {}).get("name") != name]
    return sorted(found, key=lambda p: p.get("metadata", {}).get("creationTimestamp", ""), reverse=True)


def pod_context(namespace: str, name: str, nodes: dict) -> str:
    """The pod behind an alert, its node, and its warning events. A pod that
    is gone by now (crashed and replaced, rescheduled) is answered with its
    siblings — the owner's current pods — instead of a bare 404."""
    out: list[str] = []
    try:
        pod = _k8s_get(f"/api/v1/namespaces/{namespace}/pods/{name}")
        out += _pod_lines(pod)
        node = pod.get("spec", {}).get("nodeName", "")
        if node:
            out.append(node_summary(node, nodes))
    except urllib.error.HTTPError as e:
        if e.code != 404:
            out.append(f"(could not read pod {namespace}/{name}: HTTP {e.code})")
        else:
            out.append(f"Pod {namespace}/{name} no longer exists (deleted or replaced).")
            siblings = _current_siblings(namespace, name)
            if siblings:
                out.append("Current pods of the same owner:")
                for p in siblings[:5]:
                    out += _pod_lines(p)
                    node = p.get("spec", {}).get("nodeName", "")
                    if node:
                        out.append(node_summary(node, nodes))
            else:
                out.append("No current pods of the same owner.")
    out.append(query_pod_events(namespace, name))
    # Siblings often share a node; print each node line once.
    seen, unique = set(), []
    for line in out:
        if line.startswith("Node ") and line in seen:
            continue
        seen.add(line)
        unique.append(line)
    return "\n".join(unique)


def fetch_active_alerts() -> list[dict]:
    url = f"{ALERTMANAGER_URL}/api/v2/alerts?active=true&silenced=false&inhibited=false"
    with urllib.request.urlopen(url, timeout=10) as resp:
        return json.loads(resp.read())


def _label_text(labels: dict) -> str:
    return ", ".join(f"{k}={v}" for k, v in sorted(labels.items()) if k not in SKIP_LABELS)


def active_alerts_section(alerts: list[dict], exclude: set[str], now: datetime | None = None) -> str:
    now = now or datetime.now(timezone.utc)
    fresh, chronic = [], {}
    for a in alerts:
        labels = a.get("labels", {})
        name = labels.get("alertname", "?")
        fingerprint = a.get("fingerprint")
        if name in NOISE_ALERTS or (fingerprint and fingerprint in exclude):
            continue
        started = _parse_time(a.get("startsAt", ""))
        summary = a.get("annotations", {}).get("summary") or a.get("annotations", {}).get("description", "")
        severity = labels.get("severity", "-")
        # An unreadable start time is shown, not filed as known background.
        if started is None or (now - started).total_seconds() <= FRESH_SECONDS:
            since = f"started {_age(a.get('startsAt', ''), now)} ago" if started else "start time unknown"
            fresh.append(f"- {name} [{severity}] {_label_text(labels)} — {summary} ({since})")
        else:
            entry = chronic.setdefault(name, {"count": 0, "severity": severity, "example": summary})
            entry["count"] += 1
            if _SEVERITY_RANK.get(severity, 0) > _SEVERITY_RANK.get(entry["severity"], 0):
                entry["severity"] = severity
    if not fresh and not chronic:
        return "(no other alerts are firing)"
    out = []
    if fresh:
        out += ["Started in the last 2 hours:"] + fresh
    if chronic:
        out.append("Long-standing (firing for over 2 hours, probably known):")
        for name, e in sorted(chronic.items()):
            out.append(f"- {name} x{e['count']} [{e['severity']}] — e.g. {e['example'][:150]}")
    return "\n".join(out)


def alert_context(alert: dict, nodes: dict) -> dict:
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})
    header_lines = [
        f"{labels.get('alertname', 'unknown')} [{labels.get('severity', '-')}]: {annotations.get('summary', '')}",
        f"Started: {alert.get('startsAt', '?')}",
    ]
    if _label_text(labels):
        header_lines.append(f"Labels: {_label_text(labels)}")
    if annotations.get("description"):
        header_lines.append(f"What this alert means: {annotations['description']}")

    logs: list[str] = []
    raw_query = annotations.get("logsql_query", "")
    if raw_query:
        query = scope_to_source(strip_aggregation(raw_query), labels)
        if LOG_SURROUNDING_LINES > 0:
            query += f" | stream_context before {LOG_SURROUNDING_LINES} after {LOG_SURROUNDING_LINES}"
        # Without an explicit order a limited query returns the OLDEST
        # records; take the newest and put them back in time order.
        query += f" | sort by (_time desc) | limit {LOG_FETCH_LIMIT}"
        try:
            logs = compress_lines(list(reversed(query_victorialogs(query, LOG_FETCH_LIMIT))), LOG_CONTEXT_LINES)
        except Exception as e:  # noqa: BLE001 - missing context must not stop the e-mail
            print(f"victorialogs query failed for {labels.get('alertname')}: {e}", file=sys.stderr)
            logs = [f"(log query failed: {e})"]

    k8s = ""
    if labels.get("src_namespace") and labels.get("src_pod"):
        try:
            k8s = pod_context(labels["src_namespace"], labels["src_pod"], nodes)
        except Exception as e:  # noqa: BLE001 - missing context must not stop the e-mail
            k8s = f"(could not read pod: {e})"
    return {"header": redact("\n".join(header_lines)), "k8s": redact(k8s), "logs": logs}


def _render(group: str, total: int, contexts: list[dict], logs: list[list[str]], cluster: str) -> str:
    shown = len(contexts)
    more = f" ({total - shown} more not shown)" if total > shown else ""
    parts = [f"Alert group {group}: {total} firing alert(s){more}.\n"]
    for i, (ctx, lines) in enumerate(zip(contexts, logs), 1):
        parts.append(f"### Alert {i}\n{ctx['header']}\n")
        if ctx.get("k8s"):
            parts.append(f"Kubernetes:\n{ctx['k8s']}\n")
        if lines:
            parts.append(
                "Log lines (oldest first; matches with surrounding lines, repeats folded):\n" + "\n".join(lines) + "\n"
            )
    parts.append(f"### Other alerts firing in the cluster now\n{cluster}\n")
    parts.append(_final_instruction())
    return "\n".join(parts)


def _final_instruction() -> str:
    # Last in the prompt, where models heed it most: with only the system
    # prompt asking for the language, answers drifted back to English.
    return (
        f"Diagnose this alert group in the required format. Write the entire answer in {DIAGNOSIS_LANGUAGE}, "
        "section headings included; keep commands, resource names and quoted log text as they are."
    )


def build_prompt(
    group: str, contexts: list[dict], cluster: str, total: int | None = None, system_chars: int = 0
) -> str:
    """Fits the prompt into what PROMPT_CHAR_BUDGET leaves after the system
    prompt (runbook included) by dropping, one at a time, the oldest log line
    of whichever alert has the most log text left, then by cutting the
    cluster list — the newest lines and the alert headers matter most."""
    budget = max(PROMPT_CHAR_BUDGET - system_chars, 1000)
    total = total if total is not None else len(contexts)
    logs = [list(c.get("logs", [])) for c in contexts]
    dropped = [0] * len(logs)

    def render(cluster_text: str) -> str:
        marked = [([f"({d} earlier lines omitted)"] if d else []) + lines for d, lines in zip(dropped, logs)]
        return _render(group, total, contexts, marked, cluster_text)

    prompt = render(cluster)
    while len(prompt) > budget and any(logs):
        excess = len(prompt) - budget
        while excess > 0 and any(logs):
            i = max(range(len(logs)), key=lambda k: sum(len(x) + 1 for x in logs[k]))
            line = logs[i].pop(0)
            omitted = re.fullmatch(r"\((\d+) earlier lines omitted\)", line)
            dropped[i] += int(omitted.group(1)) if omitted else 1
            excess -= len(line) + 1
        prompt = render(cluster)
    if len(prompt) > budget:
        keep = max(len(cluster) - (len(prompt) - budget) - 10, 0)
        prompt = render(cluster[:keep] + "\n(cut)")
    if len(prompt) > budget:
        tail = "\n…\n" + _final_instruction()
        prompt = prompt[: max(budget - len(tail), 0)] + tail
    return prompt[:budget]


def system_prompt() -> str:
    return _with_runbook(BASE_SYSTEM_PROMPT.format(language=DIAGNOSIS_LANGUAGE))


def _with_runbook(prompt: str) -> str:
    try:
        with open(RUNBOOK_FILE, encoding="utf-8") as f:
            runbook = f.read().strip()
    except OSError:
        runbook = ""
    if runbook:
        prompt += f"\n\n# Runbook for this cluster\n\n{runbook}"
    return prompt


def ask_llm(system: str, prompt: str) -> str:
    if LLM_API == "openai":
        return ask_openai(system, prompt)
    payload = json.dumps(
        {
            "model": LLM_MODEL,
            "system": system,
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
            "options": {"num_predict": LLM_MAX_TOKENS, "temperature": LLM_TEMPERATURE},
        }
    ).encode()
    req = urllib.request.Request(
        f"{LLM_URL}/api/generate", data=payload, headers={"Content-Type": "application/json"}
    )
    # This is the SAME shared Ollama instance OpenWebUI chat uses, with only
    # OLLAMA_NUM_PARALLEL=2 slots — a live chat reply (which does NOT get
    # think:false, so it can run long) can occupy both, leaving this request
    # queued rather than actively generating. A short timeout would then read
    # as "LLM unavailable" for a request that just hadn't reached the front
    # of the queue yet. The slack here is for queueing, not for the model
    # being slow.
    with urllib.request.urlopen(req, timeout=300) as resp:
        data = json.loads(resp.read())
    return data.get("response", "").strip()


def ask_openai(system: str, prompt: str) -> str:
    payload = json.dumps(
        {
            "model": LLM_MODEL,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": prompt}],
            "stream": False,
            "max_tokens": LLM_MAX_TOKENS,
            "temperature": LLM_TEMPERATURE,
            # Same reason as think:false above: a reasoning model spends the
            # token budget thinking and returns empty content. llama.cpp and
            # vLLM pass this to the chat template.
            "chat_template_kwargs": {"enable_thinking": False},
        }
    ).encode()
    req = urllib.request.Request(
        f"{LLM_URL}/chat/completions", data=payload, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        data = json.loads(resp.read())
    return (data["choices"][0]["message"].get("content") or "").strip()


def send_email(subject: str, body: str, html_body: str = "", attachments: tuple = ()) -> None:
    """Plain text, or text + HTML alternatives with (filename, MIME type,
    bytes) attachments."""
    if not html_body and not attachments:
        msg = MIMEText(body, "plain", "utf-8")
    else:
        msg = MIMEMultipart("mixed")
        alternative = MIMEMultipart("alternative")
        alternative.attach(MIMEText(body, "plain", "utf-8"))
        if html_body:
            alternative.attach(MIMEText(html_body, "html", "utf-8"))
        msg.attach(alternative)
        for filename, mime_type, data in attachments:
            part = MIMEApplication(data, _subtype=mime_type.split("/", 1)[1])
            part.add_header("Content-Disposition", "attachment", filename=filename)
            msg.attach(part)
    msg["Subject"] = subject
    msg["From"] = SMTP_FROM
    msg["To"] = ALERT_EMAIL_TO
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, local_hostname=SMTP_HELLO, timeout=15) as s:
        s.send_message(msg)


def push_notification(title: str, message: str, severity: str) -> None:
    """ntfy JSON publishing (POST to the server root with the topic in the
    body): unlike header-based publishing it carries non-ASCII titles."""
    if not PUSH_URL:
        return None
    parts = urllib.parse.urlsplit(PUSH_URL)

    def cut(text: str, limit: int) -> str:
        data = text.encode()
        return text if len(data) <= limit else data[: max(0, limit - 3)].decode("utf-8", errors="ignore") + "…"

    def body(title: str, message: str) -> bytes:
        return json.dumps(
            {
                "topic": parts.path.strip("/"),
                "title": title,
                "message": message,
                "priority": 4 if severity == "critical" else 3,
                "tags": ["robot"],
            },
            # UTF-8 as is: \uXXXX escapes would triple a Cyrillic answer.
            ensure_ascii=False,
        ).encode()

    title, message = cut(title, 200), cut(message, PUSH_MAX_BYTES)
    payload = body(title, message)
    # Quotes and newlines escape to 2 bytes, control characters to 6: shrink
    # the message until the whole body fits.
    while len(payload) > PUSH_MAX_BODY_BYTES and len(message) > 1:
        message = cut(message, len(message.encode()) - (len(payload) - PUSH_MAX_BODY_BYTES) - 1)
        payload = body(title, message)
    req = urllib.request.Request(
        f"{parts.scheme}://{parts.netloc}/", data=payload, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=15):
        pass
    return None


def send_email_with_retries(what: str, subject: str, body: str, **extra) -> bool:
    for attempt, delay in enumerate((*SMTP_RETRY_DELAYS, None), 1):
        try:
            send_email(subject, body, **extra)
            return True
        except Exception as e:  # noqa: BLE001 - retried, then logged; the push still goes out
            print(f"e-mail attempt {attempt} failed for {what}: {e}", file=sys.stderr)
            if delay is not None:
                time.sleep(delay)
    return False


def handle_group(payload: dict) -> None:
    """One Alertmanager notification = one group of alerts = one diagnosis,
    one e-mail and one push."""
    firing = [a for a in payload.get("alerts", []) if a.get("status") == "firing"]
    if not firing:
        return
    group = payload.get("groupLabels", {}).get("alertname") or firing[0].get("labels", {}).get("alertname", "unknown")
    severity = "critical" if any(a.get("labels", {}).get("severity") == "critical" for a in firing) else "warning"

    nodes: dict = {}
    contexts = [alert_context(a, nodes) for a in firing[:MAX_ALERTS]]
    try:
        cluster = redact(active_alerts_section(fetch_active_alerts(), {a.get("fingerprint") for a in firing}))
    except Exception as e:  # noqa: BLE001 - missing context must not stop the e-mail
        cluster = f"(could not read the other active alerts: {e})"

    system = system_prompt()
    prompt = build_prompt(group, contexts, cluster, total=len(firing), system_chars=len(system))
    try:
        diagnosis = ask_llm(system, prompt)
        if not diagnosis.strip():
            raise ValueError("empty answer")
    except Exception as e:  # noqa: BLE001 - any LLM failure still sends the e-mail, with this note
        print(f"llm request failed for {group}: {e}", file=sys.stderr)
        diagnosis = f"(LLM diagnosis unavailable: {e})"
    diagnosis = redact(diagnosis)

    first_summary = firing[0].get("annotations", {}).get("summary", "")
    subject = f"[AI diagnosis] {group} ({len(firing)}): {first_summary}"[:200]
    body = [f"--- Diagnosis by the local LLM ({LLM_MODEL}) ---\n{diagnosis}\n"]
    for ctx in contexts:
        body.append(f"=== {ctx['header']} ===")
        if ctx["k8s"]:
            body.append(ctx["k8s"])
        if ctx["logs"]:
            body.append(f"--- Log context (last 30 of {len(ctx['logs'])} lines) ---\n" + "\n".join(ctx["logs"][-30:]))
        body.append("")
    if len(firing) > len(contexts):
        body.append(f"({len(firing) - len(contexts)} more alerts in this group not shown)\n")
    body.append(f"--- Other alerts firing in the cluster ---\n{cluster}")
    subject, text = redact(subject), redact("\n".join(body))
    send_email_with_retries(group, subject, text)

    try:
        push_notification(redact(f"{group} ({len(firing)})"), diagnosis, severity)
    except Exception as e:  # noqa: BLE001 - the push is a second channel
        print(f"push failed for {group}: {e}", file=sys.stderr)


# ── Security digest ─────────────────────────────────────────────────────────
#
# trivy-operator's VulnerabilityReports say which running images carry
# fixable vulnerabilities; the registries say whether a newer tag exists. A
# digest (LLM advice, an HTML e-mail with the inventory of every running image
# as an .xlsx attachment, and a push) goes out only when something changed
# since the last one: a vulnerability not reported before, or a newer tag for
# an affected image. Vulnerabilities that went away don't trigger one; the
# next digest lists them as fixed. What the last digest reported lives in a
# ConfigMap, so a restart doesn't resend it.

SECURITY_SYSTEM_PROMPT = """You are the security assistant for a Kubernetes cluster. You get the container images \
running in the cluster that have fixable vulnerabilities (from trivy-operator), the workloads that run them, and \
for each image whether its registry has a newer tag. Findings marked [NEW] appeared since the last digest; images \
marked [UPDATE AVAILABLE] got a newer tag since then.

Rules:
- Base every claim on the data given. A newer tag is not proof that it fixes the vulnerability: say to check its \
release notes or scan it before rolling it out.
- Order by what to do first: images with a newer tag, most exposed and most severe first; then images with no \
newer tag yet.
- For an image with no newer tag, say it waits for upstream; name a mitigation only when the data supports one.
- Recommend switching a service off only when all of these hold: the runbook marks it as non-critical, the runbook \
or the data shows it is reachable from outside the cluster, and a finding is remotely exploitable with no newer \
image. Otherwise never suggest switching anything off.
- Changes go through infrastructure-as-code: say what to bump and where (image tag, Helm chart version). Never \
suggest commands that change the cluster.
- Be specific and short. No filler, no generic advice.

Write the whole answer in {language}, as plain text with these sections, each heading written in {language}:
1. Summary: one or two sentences on the state as a whole. This part is also sent as a push notification, so it \
must stand on its own.
2. Update now: per image with a newer tag, what to bump, where, and why it comes first.
3. Wait for upstream: images with no newer tag, and a mitigation only where justified."""

_DOCKER_HUB = {"docker.io", "index.docker.io", "registry-1.docker.io"}
_VERSION_TAG = re.compile(r"^(v?)(\d+(?:\.\d+)*)(.*)$")
# Pages of a registry's tag list read at most; past this the list is treated
# as unknown rather than wrongly "nothing newer" (pages come in name order).
MAX_TAG_PAGES = 50
# Findings per image shown to the model and in the e-mail; the rest are counted.
MAX_CVES_PER_IMAGE = 8
SECURITY_DIGEST_RETRY = 300
_STATUS_ORDER = ["patch available", "newer available", "unknown", "floating tag", "digest only", "up to date"]
_tags_cache: dict = {}


def parse_image(ref: str) -> tuple[str, str, str]:
    """(registry, repository, tag) of an image reference, Docker Hub spelled
    one way (docker.io, library/ for official images); tag "" when the image
    is referenced by digest only."""
    name, _, digest = ref.partition("@")
    tag = ""
    if ":" in name.rsplit("/", 1)[-1]:
        name, tag = name.rsplit(":", 1)
    elif not digest:
        tag = "latest"
    first, _, rest = name.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        registry, repository = first, rest
    else:
        registry, repository = "docker.io", name
    if registry in _DOCKER_HUB:
        registry = "docker.io"
        if "/" not in repository:
            repository = f"library/{repository}"
    return registry, repository, tag


def image_key(registry: str, repository: str, tag: str) -> str:
    registry = "docker.io" if registry in _DOCKER_HUB else registry
    return f"{registry}/{repository}:{tag}" if tag else f"{registry}/{repository}"


def active_replicasets(pods: list[dict]) -> set[str]:
    """ReplicaSets that still own pods: a Deployment keeps old ReplicaSets
    (scaled to 0) and trivy-operator keeps their reports."""
    out = set()
    for p in pods:
        meta = p.get("metadata") or {}
        for ref in meta.get("ownerReferences") or []:
            if ref.get("kind") == "ReplicaSet":
                out.add(f"{meta.get('namespace')}/{ref.get('name')}")
    return out


def _report_image(report: dict) -> tuple[str, str, str]:
    rep = report.get("report") or {}
    artifact = rep.get("artifact") or {}
    return (rep.get("registry") or {}).get("server") or "", artifact.get("repository") or "", artifact.get("tag") or ""


def _report_labels(report: dict) -> dict:
    return (report.get("metadata") or {}).get("labels") or {}


def _report_is_current(report: dict, active_rs: set[str]) -> bool:
    labels = _report_labels(report)
    if labels.get("trivy-operator.resource.kind") != "ReplicaSet":
        return True
    return f"{labels.get('trivy-operator.resource.namespace')}/{labels.get('trivy-operator.resource.name')}" in active_rs


def workload_label(namespace: str, kind: str, name: str) -> str:
    """namespace/kind/name, a Deployment's ReplicaSet shown as the Deployment."""
    # Same pod-template-hash alphabet as _current_siblings.
    if kind == "ReplicaSet" and re.search(r"-[bcdfghjklmnpqrstvwxz2456789]{5,10}$", name):
        kind, name = "Deployment", name.rsplit("-", 1)[0]
    return f"{namespace}/{kind}/{name}"


def _workload(pod: dict) -> str:
    meta = pod.get("metadata") or {}
    owners = meta.get("ownerReferences") or [{"kind": "Pod", "name": meta.get("name", "?")}]
    return workload_label(meta.get("namespace", "?"), owners[0].get("kind", "?"), owners[0].get("name", "?"))


def _some(items, limit: int = 6) -> str:
    items = sorted(items)
    return ", ".join(items[:limit]) + (f" (+{len(items) - limit} more)" if len(items) > limit else "")


def collect_findings(reports: list[dict], active_rs: set[str]) -> dict[str, dict]:
    """Images with vulnerabilities at SECURITY_SEVERITIES, keyed by image
    reference: their findings (one per vulnerability and package) and the
    workloads running them."""
    out: dict[str, dict] = {}
    for report in reports:
        if not _report_is_current(report, active_rs):
            continue
        vulns = [
            v for v in (report.get("report") or {}).get("vulnerabilities") or []
            if isinstance(v, dict) and v.get("severity") in SECURITY_SEVERITIES
        ]
        if not vulns:
            continue
        registry, repository, tag = _report_image(report)
        registry = "docker.io" if registry in _DOCKER_HUB else registry
        entry = out.setdefault(
            image_key(registry, repository, tag),
            {"registry": registry, "repository": repository, "tag": tag, "vulns": [], "workloads": set()},
        )
        labels = _report_labels(report)
        entry["workloads"].add(
            workload_label(
                labels.get("trivy-operator.resource.namespace", "?"),
                labels.get("trivy-operator.resource.kind", "?"),
                labels.get("trivy-operator.resource.name", "?"),
            )
        )
        seen = {(v["id"], v["package"], v["installed"]) for v in entry["vulns"]}
        for v in vulns:
            finding = {
                "id": v.get("vulnerabilityID") or "?",
                "package": v.get("resource") or "",
                "installed": v.get("installedVersion") or "",
                "fixed": v.get("fixedVersion") or "",
                "score": v.get("score"),
                "title": v.get("title") or "",
                "severity": v.get("severity") or "",
            }
            if (finding["id"], finding["package"], finding["installed"]) not in seen:
                seen.add((finding["id"], finding["package"], finding["installed"]))
                entry["vulns"].append(finding)
    return out


def newer_versions(tag: str, tags: list[str]) -> tuple[str, str]:
    """(newest patch, newest overall) among tags of the same flavour as `tag`
    (same "v" prefix, same suffix such as -alpine, same number of version
    parts) — each "" when nothing newer exists. Pre-releases differ in suffix
    and never count. Only x.y.z tags have patches: in a two-part tag (3.20,
    18.6) the last part is a minor for some projects and a patch for others."""
    m = _VERSION_TAG.match(tag)
    if not m:
        return "", ""
    prefix, suffix = m.group(1), m.group(3)
    current = tuple(int(x) for x in m.group(2).split("."))
    candidates = []
    for t in tags:
        mm = _VERSION_TAG.match(t)
        if not mm or mm.group(1) != prefix or mm.group(3) != suffix:
            continue
        version = tuple(int(x) for x in mm.group(2).split("."))
        if len(version) == len(current) and version > current:
            candidates.append((version, t))
    if not candidates:
        return "", ""
    patches = [c for c in candidates if len(current) >= 3 and c[0][:-1] == current[:-1]]
    return (max(patches)[1] if patches else ""), max(candidates)[1]


def format_newer(patch: str, latest: str) -> str:
    if patch and latest and patch != latest:
        return f"{patch} (latest {latest})"
    return patch or latest


def newer_tag(tag: str, tags: list[str]) -> str:
    return format_newer(*newer_versions(tag, tags))


class _SafeRedirect(urllib.request.HTTPRedirectHandler):
    """Registries may redirect (registry.k8s.io sends tag lists to another
    host): follow https only, and never carry the bearer token along."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith("https://"):
            return None
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            new.remove_header("Authorization")
        return new


_REGISTRY_OPENER = urllib.request.build_opener(_SafeRedirect)


def _registry_json(url: str, token: str | None = None) -> tuple[dict, str]:
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with _REGISTRY_OPENER.open(urllib.request.Request(url, headers=headers), timeout=20) as resp:
        return json.loads(resp.read()), resp.headers.get("Link", "")


def _same_domain(host: str, other: str) -> bool:
    """Whether `other` is `host` or shares its parent domain (Docker Hub's
    registry-1.docker.io hands out tokens from auth.docker.io)."""
    parent = ".".join(host.split(".")[-2:])
    return other == host or other == parent or other.endswith("." + parent)


def list_tags(registry: str, repository: str) -> list[str] | None:
    """Every tag of a public repository through the registry v2 API, with the
    anonymous token most registries hand out on a 401; None when the
    repository is private, unreachable, answers oddly or has too many pages.
    The registry steers where the token comes from and where the next page
    is: a token realm is fetched only over https on the registry's own
    domain, and pages are followed only over https on the registry's host,
    so neither request nor bearer token goes anywhere else."""
    host = "registry-1.docker.io" if registry in _DOCKER_HUB else registry
    base = f"https://{host}"
    url, token, tags = f"{base}/v2/{repository}/tags/list?n=1000", None, []
    try:
        for _ in range(MAX_TAG_PAGES):
            try:
                data, link = _registry_json(url, token)
            except urllib.error.HTTPError as e:
                if e.code != 401 or token is not None:
                    return None
                params = dict(re.findall(r'(\w+)="([^"]*)"', e.headers.get("WWW-Authenticate", "")))
                realm = urllib.parse.urlsplit(params.get("realm", ""))
                if realm.scheme != "https" or not _same_domain(host, realm.hostname or ""):
                    return None
                query = {"service": params.get("service", ""), "scope": params.get("scope") or f"repository:{repository}:pull"}
                answer, _ = _registry_json(params["realm"] + "?" + urllib.parse.urlencode(query))
                token = answer.get("token") or answer.get("access_token")
                if not token:
                    return None
                continue
            tags += [t for t in data.get("tags") or [] if isinstance(t, str)]
            next_page = re.search(r"<([^>]+)>", link or "")
            if not next_page:
                return tags
            url = urllib.parse.urljoin(base, next_page.group(1))
            if not url.startswith(f"{base}/"):
                return None
        return None
    except (urllib.error.URLError, OSError, ValueError, AttributeError, TypeError):
        return None


def lookup_versions(registry: str, repository: str, tag: str) -> tuple[str, str] | None:
    """newer_versions() against the registry; None when its tags can't be
    read. Cached for one digest run."""
    key = (registry, repository)
    if key not in _tags_cache:
        _tags_cache[key] = list_tags(registry, repository)
    tags = _tags_cache[key]
    return None if tags is None else newer_versions(tag, tags)


def pair_keys(findings: dict[str, dict]) -> set[str]:
    """One key per (repository, vulnerability), without the tag: bumping an
    image that still carries the same vulnerability is nothing new."""
    return {f"{f['registry']}/{f['repository']}|{v['id']}" for f in findings.values() for v in f["vulns"]}


def _repo(f: dict) -> str:
    return f"{f['registry']}/{f['repository']}"


def _line(f: dict) -> str:
    """The repository plus the tag's flavour ("v" prefix, suffix such as
    -alpine): one repository can run several flavours with their own newer tags."""
    m = _VERSION_TAG.match(f["tag"])
    return f"{_repo(f)}:{m.group(1)}*{m.group(3)}" if m else _repo(f)


def new_state(findings: dict[str, dict], newer: dict, sent_at: int, old: dict | None = None) -> dict:
    """`newer` maps an image reference to (patch, latest), or None when its
    registry could not be read: that line keeps the tags known before, so a
    registry outage can't make them look new again later."""
    old_known = (old or {}).get("known", {})
    known: dict[str, set] = {}
    for ref, v in newer.items():
        line = _line(findings[ref])
        tags = known.setdefault(line, set())
        tags.update(old_known.get(line, []) if v is None else (t for t in v if t))
    return {
        "pairs": sorted(pair_keys(findings)),
        "known": {line: sorted(tags) for line, tags in known.items() if tags},
        "sent_at": sent_at,
    }


def digest_decision(findings: dict[str, dict], newer: dict, state: dict, now: int) -> dict | None:
    """Whether a digest goes out now and why: "change" (a vulnerability, or a
    newer patch or latest tag, not reported before; tags per repository and
    flavour, so a bump within the same vulnerable line repeats nothing) or
    "reminder" (updates available but not applied, last digest older than
    SECURITY_DIGEST_REMINDER); None = stay quiet."""
    pairs, old = pair_keys(findings), set(state.get("pairs", []))
    known = state.get("known", {})
    new = pairs - old
    new_tags = {
        ref for ref, v in newer.items()
        if v and any(t and t not in known.get(_line(findings[ref]), []) for t in v)
    }
    if new or new_tags:
        reason = "change"
    elif any(_has_update(v) for v in newer.values()) and now - state.get("sent_at", 0) >= SECURITY_DIGEST_REMINDER:
        reason = "reminder"
    else:
        return None
    return {"reason": reason, "new": new, "new_tags": new_tags, "fixed": sorted(old - pairs)}


def _newer_text(v) -> str:
    if v is None:
        return "unknown (registry could not be read)"
    return format_newer(*v) or "none found"


def build_inventory(pods: list[dict], reports: list[dict]) -> list[dict]:
    """One row per image running in the cluster: where it runs, whether it is
    pinned by digest, its fixable critical/high counts and whether the
    registry has something newer. Rows with critical findings first."""
    images: dict[str, dict] = {}
    for pod in pods:
        if (pod.get("status") or {}).get("phase") in ("Succeeded", "Failed"):
            continue
        spec = pod.get("spec") or {}
        for c in (spec.get("initContainers") or []) + (spec.get("containers") or []):
            ref = (c or {}).get("image") or ""
            if not ref:
                continue
            registry, repository, tag = parse_image(ref)
            row = images.setdefault(
                image_key(registry, repository, tag),
                {"registry": registry, "repository": repository, "tag": tag, "workloads": set(), "digests": []},
            )
            row["workloads"].add(_workload(pod))
            row["digests"].append("@" in ref)

    counts: dict[str, tuple[int, int]] = {}
    active_rs = active_replicasets(pods)
    for report in reports:
        if not _report_is_current(report, active_rs):
            continue
        key = image_key(*_report_image(report))
        vulns = [v for v in (report.get("report") or {}).get("vulnerabilities") or [] if isinstance(v, dict)]
        critical = len({v.get("vulnerabilityID") for v in vulns if v.get("severity") == "CRITICAL"})
        high = len({v.get("vulnerabilityID") for v in vulns if v.get("severity") == "HIGH"})
        old = counts.get(key, (0, 0))
        counts[key] = (max(old[0], critical), max(old[1], high))

    rows = []
    for key, row in images.items():
        patch = latest = ""
        if not row["tag"]:
            status = "digest only"
        elif not _VERSION_TAG.match(row["tag"]):
            status = "floating tag"
        else:
            versions = lookup_versions(row["registry"], row["repository"], row["tag"])
            if versions is None:
                status = "unknown"
            else:
                patch, latest = versions
                status = "patch available" if patch else "newer available" if latest else "up to date"
        critical, high = counts.get(key, (0, 0))
        workloads = sorted(row["workloads"])
        rows.append({
            "image": key, "registry": row["registry"], "repository": row["repository"], "tag": row["tag"],
            "status": status, "patch": patch, "latest": latest, "critical": critical, "high": high,
            "pinned": "yes" if all(row["digests"]) else "partly" if any(row["digests"]) else "no",
            "namespaces": sorted({w.split("/", 1)[0] for w in workloads}), "workloads": workloads,
        })
    rows.sort(key=lambda r: (-r["critical"], _STATUS_ORDER.index(r["status"]), -r["high"], r["image"]))
    return rows


# ── .xlsx without a library ──
# An .xlsx is a zip of a few XML parts; this writes the smallest set Excel,
# LibreOffice and Numbers open: inline strings, a bold header row frozen with
# an autofilter, column widths, and an optional fill per row.

_XLSX_FILLS = {None: 0, "red": 2, "amber": 3, "green": 4, "grey": 5}
_XML_ILLEGAL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def _xml(text) -> str:
    return html.escape(_XML_ILLEGAL.sub("", str(text)), quote=True)


def _col(n: int) -> str:
    name = ""
    while n:
        n, r = divmod(n - 1, 26)
        name = chr(65 + r) + name
    return name


def _sheet_xml(header: list[str], rows: list[list], fills: list) -> str:
    widths = [len(str(h)) for h in header]
    for row in rows:
        for i, v in enumerate(row):
            widths[i] = max(widths[i], min(len(str(v)), 80))
    cols = "".join(f'<col min="{i}" max="{i}" width="{w + 2}" customWidth="1"/>' for i, w in enumerate(widths, 1))

    def cell(ref: str, value, style: int) -> str:
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return f'<c r="{ref}" s="{style}"><v>{value}</v></c>'
        return f'<c r="{ref}" s="{style}" t="inlineStr"><is><t xml:space="preserve">{_xml(value)}</t></is></c>'

    lines = ['<row r="1">' + "".join(cell(f"{_col(i)}1", h, 1) for i, h in enumerate(header, 1)) + "</row>"]
    for r, (row, fill) in enumerate(zip(rows, fills), 2):
        style = _XLSX_FILLS[fill]
        lines.append(f'<row r="{r}">' + "".join(cell(f"{_col(i)}{r}", v, style) for i, v in enumerate(row, 1)) + "</row>")
    last = f"{_col(len(header))}{len(rows) + 1}"
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" '
        'state="frozen"/></sheetView></sheetViews>'
        f"<cols>{cols}</cols><sheetData>{''.join(lines)}</sheetData>"
        f'<autoFilter ref="A1:{last}"/></worksheet>'
    )


def xlsx_bytes(sheets: list[tuple[str, list[str], list[list], list]]) -> bytes:
    """Workbook from (name, header, rows, per-row fill) sheets; a fill is a
    key of _XLSX_FILLS."""
    ns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    names = "".join(
        f'<sheet name="{_xml(name[:31])}" sheetId="{i}" r:id="rId{i}"/>' for i, (name, *_) in enumerate(sheets, 1)
    )
    rels = "".join(
        f'<Relationship Id="rId{i}" Type="{ns}/worksheet" Target="worksheets/sheet{i}.xml"/>'
        for i in range(1, len(sheets) + 1)
    )
    overrides = "".join(
        f'<Override PartName="/xl/worksheets/sheet{i}.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        for i in range(1, len(sheets) + 1)
    )
    fills = "".join(
        f'<fill><patternFill patternType="solid"><fgColor rgb="{rgb}"/></patternFill></fill>'
        for rgb in ("FFFADBD8", "FFFCF3CF", "FFD5F5E3", "FFEAECEE")
    )
    # cellXfs: 0 plain, 1 bold header, then one per fill (index = _XLSX_FILLS value).
    xfs = '<xf numFmtId="0" fontId="0" fillId="0" borderId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" applyFont="1"/>'
    xfs += "".join(f'<xf numFmtId="0" fontId="0" fillId="{f}" borderId="0" applyFill="1"/>' for f in range(2, 6))
    parts = {
        "[Content_Types].xml": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/xl/workbook.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
            '<Override PartName="/xl/styles.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
            f"{overrides}</Types>"
        ),
        "_rels/.rels": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            f'<Relationship Id="rId1" Type="{ns}/officeDocument" Target="xl/workbook.xml"/></Relationships>'
        ),
        "xl/workbook.xml": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
            f'xmlns:r="{ns}"><sheets>{names}</sheets></workbook>'
        ),
        "xl/_rels/workbook.xml.rels": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            f'{rels}<Relationship Id="rId{len(sheets) + 1}" Type="{ns}/styles" Target="styles.xml"/></Relationships>'
        ),
        "xl/styles.xml": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
            '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
            '<fills count="6"><fill><patternFill patternType="none"/></fill>'
            f'<fill><patternFill patternType="gray125"/></fill>{fills}</fills>'
            '<borders count="1"><border/></borders>'
            '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
            f'<cellXfs count="6">{xfs}</cellXfs>'
            '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'
        ),
    }
    for i, (_, header, rows, row_fills) in enumerate(sheets, 1):
        parts[f"xl/worksheets/sheet{i}.xml"] = _sheet_xml(header, rows, row_fills)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, content in parts.items():
            z.writestr(name, content)
    return buf.getvalue()


_STATUS_FILL = {"patch available": "amber", "newer available": "amber", "up to date": "green", "unknown": "grey",
                "floating tag": "grey", "digest only": "grey"}


def inventory_xlsx(rows: list[dict], findings: dict[str, dict], decision: dict) -> bytes:
    images = [
        [r["image"], r["tag"], r["status"], r["patch"], r["latest"], r["critical"], r["high"], r["pinned"],
         ", ".join(r["namespaces"]), ", ".join(r["workloads"])]
        for r in rows
    ]
    image_fills = ["red" if r["critical"] else _STATUS_FILL[r["status"]] for r in rows]
    vulns, vuln_fills = [], []
    for ref, f in sorted(findings.items()):
        for v, is_new in _ordered_vulns(f, decision["new"]):
            vulns.append([ref, v["id"], v["severity"], v["score"] if v["score"] is not None else "", v["package"],
                          v["installed"], v["fixed"], "yes" if is_new else "", v["title"], _advisory_url(v["id"]),
                          ", ".join(sorted(f["workloads"]))])
            vuln_fills.append("red" if is_new else None)
    return xlsx_bytes([
        ("Images", ["Image", "Tag", "Status", "Newer patch", "Latest", "Fixable critical", "Fixable high",
                    "Pinned by digest", "Namespaces", "Workloads"], images, image_fills),
        ("Findings", ["Image", "Vulnerability", "Severity", "Score", "Package", "Installed", "Fixed in", "New",
                      "Title", "Advisory", "Workloads"], vulns, vuln_fills),
    ])


def _advisory_url(vuln_id: str) -> str:
    if vuln_id.startswith("GHSA-"):
        return f"https://github.com/advisories/{vuln_id}"
    if vuln_id.startswith("CVE-"):
        return f"https://nvd.nist.gov/vuln/detail/{vuln_id}"
    return ""


def _score(v: dict) -> float:
    return v["score"] if isinstance(v["score"], (int, float)) else 0


def _ordered_vulns(f: dict, new: set[str]) -> list[tuple[dict, bool]]:
    items = [(v, f"{_repo(f)}|{v['id']}" in new) for v in f["vulns"]]
    return sorted(items, key=lambda x: (not x[1], -_score(x[0]), x[0]["id"], x[0]["package"]))


def _has_update(v) -> bool:
    return bool(v and (v[0] or v[1]))


def _ordered_images(findings: dict[str, dict], newer: dict, decision: dict) -> list[str]:
    def rank(ref: str):
        has_new = any(is_new for _, is_new in _ordered_vulns(findings[ref], decision["new"]))
        return (not _has_update(newer.get(ref)), not has_new, ref)

    return sorted(findings, key=rank)


def security_system_prompt() -> str:
    return _with_runbook(SECURITY_SYSTEM_PROMPT.format(language=DIAGNOSIS_LANGUAGE))


def _security_final_instruction() -> str:
    return (
        f"Write the security digest in the required format. Write the entire answer in {DIAGNOSIS_LANGUAGE}, "
        "section headings included; keep image names, tags and vulnerability IDs as they are."
    )


def security_prompt(findings: dict[str, dict], newer: dict, decision: dict, system_chars: int = 0) -> str:
    budget = max(PROMPT_CHAR_BUDGET - system_chars, 1000)
    tail = "\n" + _security_final_instruction()
    head = f"{len(findings)} image(s) with fixable vulnerabilities ({', '.join(sorted(SECURITY_SEVERITIES))}).\n"
    blocks = []
    for ref in _ordered_images(findings, newer, decision):
        f = findings[ref]
        mark = " [UPDATE AVAILABLE]" if ref in decision["new_tags"] else ""
        lines = [f"### Image {ref}{mark} — newer tag: {_newer_text(newer.get(ref))}"]
        lines.append("Runs in: " + _some(f["workloads"], 5))
        cves = _ordered_vulns(f, decision["new"])
        for v, is_new in cves[:MAX_CVES_PER_IMAGE]:
            score = f", score {v['score']}" if v["score"] is not None else ""
            lines.append(
                f"  {'[NEW] ' if is_new else ''}{v['id']} {v['package']} {v['installed']} -> {v['fixed']}{score}: {v['title'][:160]}"
            )
        if len(cves) > MAX_CVES_PER_IMAGE:
            lines.append(f"  ({len(cves) - MAX_CVES_PER_IMAGE} more)")
        blocks.append("\n".join(lines))
    if decision["fixed"]:
        blocks.append("### Gone since the last digest\n" + "\n".join(f"- {p.replace('|', ' ')}" for p in decision["fixed"]))
    prompt = head + "\n\n".join(blocks)
    if len(prompt) + len(tail) > budget:
        prompt = prompt[: budget - len(tail) - 6] + "\n(cut)"
    return redact(prompt) + tail


def _summary_line(findings: dict, newer: dict, decision: dict, rows: list[dict]) -> str:
    updates = sum(1 for ref in findings if _has_update(newer.get(ref)))
    return (
        f"{len(rows)} images running, {len(findings)} with fixable {'/'.join(sorted(SECURITY_SEVERITIES)).lower()} "
        f"vulnerabilities, {updates} with a newer tag; {len(decision['new'])} new, {len(decision['fixed'])} fixed "
        "since the last digest."
    )


def digest_text(advice: str, findings: dict, newer: dict, decision: dict, rows: list[dict]) -> str:
    out = [_summary_line(findings, newer, decision, rows), "", f"--- Advice by the local LLM ({LLM_MODEL}) ---", advice, ""]
    for ref in _ordered_images(findings, newer, decision):
        f = findings[ref]
        out.append(f"=== {ref} — newer tag: {_newer_text(newer.get(ref))} ===")
        out.append("Runs in: " + ", ".join(sorted(f["workloads"])))
        for v, is_new in _ordered_vulns(f, decision["new"]):
            out.append(f"  {'[NEW] ' if is_new else ''}{v['id']} {v['package']} {v['installed']} -> {v['fixed']}: {v['title']}")
        out.append("")
    if decision["fixed"]:
        out.append("--- Fixed since the last digest ---")
        out += [f"  {p.replace('|', ' ')}" for p in decision["fixed"]]
    out.append("\nInventory of every running image: attached .xlsx.")
    return "\n".join(out)


_CARD = "border:1px solid #e3e6ea;border-radius:10px;padding:14px 16px;margin:0 0 14px;background:#ffffff"


def _badge(text: str, bg: str, fg: str = "#ffffff") -> str:
    return (
        f'<span style="display:inline-block;padding:1px 7px;border-radius:9px;font-size:11px;font-weight:600;'
        f'background:{bg};color:{fg};margin-right:6px">{html.escape(text)}</span>'
    )


def digest_html(advice: str, findings: dict, newer: dict, decision: dict, rows: list[dict], now: int) -> str:
    e = html.escape
    updates = sum(1 for ref in findings if _has_update(newer.get(ref)))
    stats = [
        (len(rows), "images running", "#2c3e50"),
        (len(findings), "with " + "/".join(sorted(SECURITY_SEVERITIES)).lower(), "#c0392b"),
        (updates, "can be updated", "#d68910"),
        (len(decision["new"]), "new findings", "#8e44ad"),
        (len(decision["fixed"]), "fixed", "#1e8449"),
    ]
    tiles = "".join(
        f'<td style="padding:4px"><div style="{_CARD};margin:0;text-align:center;min-width:92px">'
        f'<div style="font-size:26px;font-weight:700;color:{color}">{n}</div>'
        f'<div style="font-size:12px;color:#5d6d7e">{e(label)}</div></div></td>'
        for n, label, color in stats
    )
    when = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    title = "Weekly reminder: updates waiting" if decision["reason"] == "reminder" else "Security digest"
    parts = [
        '<div style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#1c2833;'
        'background:#f4f6f8;padding:20px;max-width:900px">',
        f'<div style="font-size:22px;font-weight:700;margin-bottom:2px">{e(title)}</div>',
        f'<div style="font-size:13px;color:#5d6d7e;margin-bottom:14px">{e(when)}</div>',
        f'<table style="border-collapse:collapse;margin:0 0 14px"><tr>{tiles}</tr></table>',
        f'<div style="{_CARD};border-left:4px solid #2e86c1"><div style="font-size:15px;font-weight:700;'
        f'margin-bottom:8px">Advice <span style="font-weight:400;color:#85929e;font-size:12px">({e(LLM_MODEL)})</span></div>'
        f'<div style="white-space:pre-wrap;font-size:14px;line-height:1.5">{e(advice)}</div></div>',
    ]
    for ref in _ordered_images(findings, newer, decision):
        f = findings[ref]
        badges = ""
        if ref in decision["new_tags"]:
            badges += _badge("UPDATE AVAILABLE", "#d68910")
        versions = newer.get(ref)
        if versions is None:
            update = '<span style="color:#b9770e">registry could not be read: newer tags unknown</span>'
        elif _has_update(versions):
            update = f'newer tag <b style="font-family:monospace">{e(format_newer(*versions))}</b>'
        else:
            update = '<span style="color:#85929e">no newer tag yet</span>'
        cve_rows = []
        for v, is_new in _ordered_vulns(f, decision["new"]):
            link = _advisory_url(v["id"])
            name = f'<a href="{e(link)}" style="color:#2e86c1;text-decoration:none">{e(v["id"])}</a>' if link else e(v["id"])
            score = "" if v["score"] is None else f"{v['score']:.1f}" if isinstance(v["score"], (int, float)) else e(str(v["score"]))
            cve_rows.append(
                '<tr style="border-top:1px solid #eef0f2">'
                f'<td style="padding:6px 8px;white-space:nowrap">{_badge("NEW", "#8e44ad") if is_new else ""}{name}</td>'
                f'<td style="padding:6px 8px;font-family:monospace;font-size:12px">{e(v["package"])} '
                f'{e(v["installed"])} &rarr; <b>{e(v["fixed"])}</b></td>'
                f'<td style="padding:6px 8px;text-align:right;color:#c0392b;font-weight:600">{score}</td>'
                f'<td style="padding:6px 8px;font-size:12px;color:#34495e">{e(v["title"][:200])}</td></tr>'
            )
        parts.append(
            f'<div style="{_CARD}">'
            f'<div style="font-family:monospace;font-size:14px;font-weight:700;word-break:break-all">{badges}{e(ref)}</div>'
            f'<div style="font-size:13px;margin:4px 0 2px">{update}</div>'
            f'<div style="font-size:12px;color:#5d6d7e;margin-bottom:8px">runs in {e(_some(f["workloads"]))}</div>'
            f'<table style="border-collapse:collapse;width:100%;font-size:13px">{"".join(cve_rows)}</table></div>'
        )
    if decision["fixed"]:
        items = "".join(f'<li style="font-family:monospace;font-size:12px">{e(p.replace("|", "  "))}</li>' for p in decision["fixed"])
        parts.append(
            f'<div style="{_CARD};border-left:4px solid #1e8449"><div style="font-size:15px;font-weight:700">'
            f'Fixed since the last digest</div><ul style="margin:8px 0 0;padding-left:20px">{items}</ul></div>'
        )
    parts.append(
        '<div style="font-size:12px;color:#85929e">The attached workbook lists every running image (Images) and every '
        "finding (Findings). A newer tag is not proof of a fix: check its release notes or scan it first.</div></div>"
    )
    return "".join(parts)


def fetch_vulnerability_reports() -> list[dict]:
    return _k8s_get("/apis/aquasecurity.github.io/v1alpha1/vulnerabilityreports").get("items", [])


def fetch_pods() -> list[dict]:
    return _k8s_get("/api/v1/pods").get("items", [])


def _state_path() -> str:
    return f"/api/v1/namespaces/{POD_NAMESPACE}/configmaps/{SECURITY_STATE_CONFIGMAP}"


def read_state() -> dict:
    """The last digest's state; anything unreadable counts as none (one
    digest repeats everything) rather than silencing digests for good."""
    raw = (_k8s_get(_state_path()).get("data") or {}).get("state.json", "")
    try:
        state = json.loads(raw) if raw else {}
    except ValueError:
        return {}
    if not isinstance(state, dict):
        return {}
    pairs, known, sent_at = state.get("pairs", []), state.get("known", {}), state.get("sent_at", 0)
    if not (
        isinstance(pairs, list)
        and all(isinstance(p, str) for p in pairs)
        and isinstance(known, dict)
        and all(isinstance(v, list) and all(isinstance(t, str) for t in v) for v in known.values())
        and isinstance(sent_at, int)
    ):
        return {}
    return state


def write_state(state: dict) -> None:
    with open(K8S_TOKEN_FILE) as f:
        token = f.read().strip()
    body = json.dumps({"data": {"state.json": json.dumps(state)}}).encode()
    req = urllib.request.Request(
        f"{K8S_API_URL}{_state_path()}",
        data=body,
        method="PATCH",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/merge-patch+json"},
    )
    with urllib.request.urlopen(req, timeout=10, context=ssl.create_default_context(cafile=K8S_CA_FILE)):
        pass


def run_security_digest(now: int | None = None) -> bool:
    """One check; False when the reports, pods or state could not be read or
    a digest reached no channel (the loop then retries soon instead of a
    whole interval later)."""
    now = int(now if now is not None else time.time())
    _tags_cache.clear()
    try:
        reports, pods, state = fetch_vulnerability_reports(), fetch_pods(), read_state()
    except Exception as e:  # noqa: BLE001 - retried soon; SecurityScanNoData covers a dead scanner
        print(f"security digest: could not read reports, pods or state: {e}", file=sys.stderr)
        return False
    findings = collect_findings(reports, active_replicasets(pods))
    newer = {
        ref: lookup_versions(f["registry"], f["repository"], f["tag"]) if f["tag"] else ("", "")
        for ref, f in findings.items()
    }
    decision = digest_decision(findings, newer, state, now)
    if decision is None:
        return True

    system = security_system_prompt()
    prompt = security_prompt(findings, newer, decision, system_chars=len(system))
    try:
        with _WORKERS:
            advice = ask_llm(system, prompt)
        if not advice.strip():
            raise ValueError("empty answer")
    except Exception as e:  # noqa: BLE001 - the digest goes out without advice
        print(f"security digest: llm request failed: {e}", file=sys.stderr)
        advice = f"(LLM advice unavailable: {e})"
    advice = redact(advice)

    rows = build_inventory(pods, reports)
    try:
        attachments = (("image-inventory.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                        inventory_xlsx(rows, findings, decision)),)
    except Exception as e:  # noqa: BLE001 - the digest is worth more than its attachment
        print(f"security digest: inventory failed: {e}", file=sys.stderr)
        attachments = ()
    label = []
    if decision["new"]:
        label.append(f"{len(decision['new'])} new")
    if decision["new_tags"]:
        label.append(f"{len(decision['new_tags'])} update{'s' if len(decision['new_tags']) > 1 else ''}")
    if decision["reason"] == "reminder":
        label.append("reminder")
    subject = redact(f"[Security digest] {len(findings)} images with fixable findings ({', '.join(label)})")
    text = redact(digest_text(advice, findings, newer, decision, rows))
    page = redact(digest_html(advice, findings, newer, decision, rows, now))
    mailed = send_email_with_retries("security digest", subject, text, html_body=page, attachments=attachments)
    pushed = False
    try:
        push_notification("Security digest", advice, "critical" if decision["new"] else "warning")
        pushed = bool(PUSH_URL)
    except Exception as e:  # noqa: BLE001 - the push is a second channel
        print(f"security digest: push failed: {e}", file=sys.stderr)
    # Only the mail carries the findings and the inventory: until it is
    # delivered the state stays, so the next interval sends it again (the
    # push then repeats every interval, not every retry). Neither channel
    # delivered: retried soon.
    if not mailed:
        return pushed
    try:
        write_state(new_state(findings, newer, now, state))
    except Exception as e:  # noqa: BLE001 - the next run resends; logged so a loop is visible
        print(f"security digest: could not save state: {e}", file=sys.stderr)
    return True


def security_digest_loop() -> None:
    while True:
        ok = False
        try:
            ok = run_security_digest()
        except Exception as e:  # noqa: BLE001 - one bad run must not end the loop
            print(f"security digest failed: {e}", file=sys.stderr)
        # A failed read (API blip, RBAC not applied yet on a fresh rollout)
        # is retried in minutes, not a whole interval later.
        time.sleep(SECURITY_DIGEST_INTERVAL if ok else min(SECURITY_DIGEST_RETRY, SECURITY_DIGEST_INTERVAL))


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
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            length = -1
        if not 0 <= length <= MAX_BODY_BYTES:
            self.send_response(413 if length > MAX_BODY_BYTES else 400)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = self.rfile.read(length)
        # Ack immediately: Alertmanager's webhook timeout is short (default
        # 10s) and LLM generation alone can take longer than that — an
        # ack-after-processing response risks Alertmanager treating this as
        # a failed delivery and retrying, duplicating the enrichment email.
        # Content-Length is required for this to actually work: without it
        # the client has no way to know the body is complete except by the
        # connection closing, which do_POST doesn't do until handle_group()
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
        try:
            with _WORKERS:
                handle_group(payload)
        except Exception as e:  # noqa: BLE001 - one bad notification must not affect the next
            print(f"enrichment failed for {payload.get('groupLabels')}: {e}", file=sys.stderr)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), file=sys.stderr)


if __name__ == "__main__":
    if SECURITY_DIGEST_INTERVAL > 0 and SECURITY_STATE_CONFIGMAP and POD_NAMESPACE:
        threading.Thread(target=security_digest_loop, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"alert-llm-enricher listening on :{PORT}", file=sys.stderr)
    server.serve_forever()
