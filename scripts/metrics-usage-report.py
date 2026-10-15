"""Weekly report of Prometheus metric families nobody uses.

Compares the series in Prometheus with the metric names that its rules
(alerting and recording, as loaded) and the Grafana dashboards (ConfigMaps
labelled `grafana_dashboard`, the sidecar's convention) reference. Families
with at least MIN_SERIES series that nothing references are candidates to
drop at the scrape. The full list goes to stdout (the Job's log); when there
is any, one e-mail goes to REPORT_TO through the cluster's SMTP relay.

Name extraction is textual: every identifier in a rule expression or a
dashboard that is also a metric name counts as used. Queries that select by
`{__name__=~"..."}` regex are not understood; such metrics show up as unused.

Stdlib only.
"""
import datetime
import json
import os
import re
import smtplib
import ssl
import urllib.parse
import urllib.request
from email.message import EmailMessage

PROMETHEUS = os.environ["PROMETHEUS_URL"].rstrip("/")
MIN_SERIES = int(os.environ.get("MIN_SERIES", "1000"))
TOP = int(os.environ.get("TOP", "20"))
REPORT_TO = os.environ.get("REPORT_TO", "")
REPORT_FROM = os.environ.get("REPORT_FROM", "")
SMARTHOST = os.environ.get("SMARTHOST", "")
HELO = os.environ.get("HELO", "") or None

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
API = "https://kubernetes.default.svc"
IDENT = re.compile(r"[a-zA-Z_:][a-zA-Z0-9_:]*")


def get_json(url, headers=None, context=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=300, context=context) as resp:
        return json.load(resp)


def series_per_metric():
    query = 'count by (__name__) ({__name__=~".+"})'
    url = PROMETHEUS + "/api/v1/query?" + urllib.parse.urlencode({"query": query})
    result = get_json(url)["data"]["result"]
    return {r["metric"]["__name__"]: int(float(r["value"][1])) for r in result}


def referencing_texts():
    texts = []
    for group in get_json(PROMETHEUS + "/api/v1/rules")["data"]["groups"]:
        texts.extend(rule["query"] for rule in group["rules"])
    token = open(f"{SA}/token").read()
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    cms = get_json(
        API + "/api/v1/configmaps?labelSelector=grafana_dashboard",
        {"Authorization": f"Bearer {token}"},
        ctx,
    )["items"]
    texts.extend(v for cm in cms for v in (cm.get("data") or {}).values())
    return texts, len(cms)


def main():
    series = series_per_metric()
    texts, dashboards = referencing_texts()
    used = {name for text in texts for name in IDENT.findall(text) if name in series}

    unused = sorted(
        ((n, c) for n, c in series.items() if n not in used and c >= MIN_SERIES),
        key=lambda nc: -nc[1],
    )
    total = sum(series.values())
    unused_total = sum(c for _, c in unused)

    print(f"{total} series in {len(series)} families; {len(used)} families referenced "
          f"by {len(texts)} rules and dashboard files ({dashboards} dashboard ConfigMaps)")
    print(f"unused families with >= {MIN_SERIES} series: {len(unused)}, {unused_total} series")
    for name, count in unused:
        print(f"{count:>8} {name}")

    if not unused or not (REPORT_TO and REPORT_FROM and SMARTHOST):
        return

    lines = "\n".join(f"{c:>8}  {n}" for n, c in unused[:TOP])
    more = f"\n... and {len(unused) - TOP} more (the Job's log has the full list)" if len(unused) > TOP else ""
    msg = EmailMessage()
    msg["Subject"] = (f"[metrics] {len(unused)} unused metric families, "
                      f"{unused_total} of {total} series ({100 * unused_total // max(total, 1)}%)")
    msg["From"] = REPORT_FROM
    msg["To"] = REPORT_TO
    msg["Date"] = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    msg.set_content(
        f"Prometheus families with at least {MIN_SERIES} series that no alerting or recording\n"
        f"rule and no Grafana dashboard references:\n\n{lines}{more}\n\n"
        "If nobody needs them, drop them at the scrape (the ServiceMonitor's\n"
        "metricRelabelings); each one costs Prometheus memory on every replica.\n"
        "Ad-hoc queries and dashboards selecting by {__name__=~...} are not seen.\n"
    )
    host, _, port = SMARTHOST.partition(":")
    with smtplib.SMTP(host, int(port or 25), local_hostname=HELO, timeout=60) as smtp:
        smtp.send_message(msg)
    print(f"report sent to {REPORT_TO}")


if __name__ == "__main__":
    main()
