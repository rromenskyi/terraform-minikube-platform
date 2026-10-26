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
from datetime import datetime, timezone
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
    prompt = BASE_SYSTEM_PROMPT.format(language=DIAGNOSIS_LANGUAGE)
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


def send_email(subject: str, body: str) -> None:
    msg = MIMEText(body, "plain", "utf-8")
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
    data = message.encode()
    if len(data) > PUSH_MAX_BYTES:
        message = data[: PUSH_MAX_BYTES - 3].decode("utf-8", errors="ignore") + "…"
    payload = json.dumps(
        {
            "topic": parts.path.strip("/"),
            "title": title,
            "message": message,
            "priority": 4 if severity == "critical" else 3,
            "tags": ["robot"],
        },
        # UTF-8 as is: \uXXXX escapes triple a Cyrillic answer and ntfy refuses
        # a JSON body over twice its 4 KiB message limit.
        ensure_ascii=False,
    ).encode()
    req = urllib.request.Request(
        f"{parts.scheme}://{parts.netloc}/", data=payload, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=15):
        pass
    return None


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
    for attempt, delay in enumerate((*SMTP_RETRY_DELAYS, None), 1):
        try:
            send_email(subject, text)
            break
        except Exception as e:  # noqa: BLE001 - retried, then logged; the push still goes out
            print(f"e-mail attempt {attempt} failed for {group}: {e}", file=sys.stderr)
            if delay is not None:
                time.sleep(delay)

    try:
        push_notification(redact(f"{group} ({len(firing)})"), diagnosis, severity)
    except Exception as e:  # noqa: BLE001 - the push is a second channel
        print(f"push failed for {group}: {e}", file=sys.stderr)


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
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"alert-llm-enricher listening on :{PORT}", file=sys.stderr)
    server.serve_forever()
