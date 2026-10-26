"""Tests for alert-llm-enricher.py (stdlib unittest, no cluster needed).

Run: python3 -m unittest discover -s scripts -p '*_test.py'
"""

import importlib.util
import json
import os
import pathlib
import tempfile
import threading
import unittest
import urllib.error
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

SCRIPT = pathlib.Path(__file__).with_name("alert-llm-enricher.py")


def load(**env):
    base = {
        "LLM_API": "openai",
        "LLM_URL": "http://127.0.0.1:1/v1",
        "LLM_MODEL": "m1",
        "SMTP_HELLO": "h",
        "SMTP_FROM": "f",
        "ALERT_EMAIL_TO": "t",
        "RUNBOOK_FILE": "/nonexistent/runbook.md",
        "PUSH_URL": "",
        "PROMPT_CHAR_BUDGET": "40000",
    }
    base.update(env)
    os.environ.update(base)
    spec = importlib.util.spec_from_file_location("enricher", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.sent = []
    mod.send_email = lambda subject, body: mod.sent.append((subject, body))
    return mod


def rec(t, msg):
    return {"_time": t, "_msg": msg}


class CompressLinesTest(unittest.TestCase):
    def setUp(self):
        self.m = load()

    def test_repeats_collapse_with_count_and_last_time(self):
        out = self.m.compress_lines(
            [
                rec("2026-10-25T15:31:14Z", "SETUSER a failed: connect 10.0.0.1:6379"),
                rec("2026-10-25T15:31:20Z", "SETUSER a failed: connect 10.0.0.2:6379"),
                rec("2026-10-25T15:32:00Z", "other"),
                rec("2026-10-25T15:33:09Z", "SETUSER a failed: connect 10.0.0.3:6379"),
            ],
            50,
        )
        self.assertEqual(
            out,
            [
                "15:31:14 SETUSER a failed: connect 10.0.0.1:6379  [x3, last 15:33:09]",
                "15:32:00 other",
            ],
        )

    def test_keeps_newest_lines_when_over_limit(self):
        recs = [rec(f"2026-10-25T15:00:{i:02d}Z", f"line-{chr(97 + i)}") for i in range(10)]
        out = self.m.compress_lines(recs, 3)
        self.assertEqual(out[0], "(7 earlier lines omitted)")
        self.assertEqual(out[1:], ["15:00:07 line-h", "15:00:08 line-i", "15:00:09 line-j"])

    def test_stream_context_separators_kept_once(self):
        out = self.m.compress_lines(
            [rec("2026-10-25T15:00:00Z", "---"), rec("2026-10-25T15:00:01Z", "a"),
             rec("2026-10-25T15:00:01Z", "---"), rec("2026-10-25T15:00:02Z", "---"),
             rec("2026-10-25T15:00:03Z", "b"), rec("2026-10-25T15:00:03Z", "---")],
            50,
        )
        self.assertEqual(out, ["15:00:01 a", "---", "15:00:03 b"])

    def test_long_line_truncated(self):
        out = self.m.compress_lines([rec("2026-10-25T15:00:00Z", "x" * 2000)], 5)
        self.assertLess(len(out[0]), 700)


class ActiveAlertsTest(unittest.TestCase):
    def test_fresh_listed_chronic_counted_noise_dropped(self):
        m = load()
        now = datetime(2026, 10, 26, 3, 0, tzinfo=timezone.utc)
        def a(name, started, fp, **labels):
            return {"fingerprint": fp, "startsAt": started.isoformat(), "labels": {"alertname": name, **labels},
                    "annotations": {"summary": f"{name} summary"}}
        alerts = [
            a("Watchdog", now - timedelta(days=9), "w"),
            a("KubePodCrashLooping", now - timedelta(minutes=20), "c", namespace="platform", pod="p1", severity="warning"),
            a("ImageVulnerabilities", now - timedelta(days=5), "v1", severity="warning"),
            a("ImageVulnerabilities", now - timedelta(days=4), "v2", severity="warning"),
            a("reconciler-error", now - timedelta(minutes=6), "self", severity="warning"),
        ]
        out = m.active_alerts_section(alerts, exclude={"self"}, now=now)
        self.assertIn("KubePodCrashLooping", out)
        self.assertIn("pod=p1", out)
        self.assertIn("20m ago", out)
        self.assertIn("ImageVulnerabilities x2", out)
        self.assertNotIn("Watchdog", out)
        self.assertNotIn("reconciler-error", out)


class PromptBudgetTest(unittest.TestCase):
    def test_trims_logs_to_budget_keeping_newest(self):
        m = load(PROMPT_CHAR_BUDGET="3000")
        ctx = [{"header": f"alert {i}", "k8s": "pod ok", "logs": [f"line {i}-{j} " + "x" * 50 for j in range(100)]}
               for i in range(3)]
        prompt = m.build_prompt("grp", ctx, "cluster ok")
        self.assertLessEqual(len(prompt), 3000)
        for i in range(3):
            self.assertIn(f"line {i}-99 ", prompt)
            self.assertNotIn(f"line {i}-0 ", prompt)
        self.assertIn("cluster ok", prompt)


class SystemPromptTest(unittest.TestCase):
    def test_runbook_appended_when_present(self):
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
            f.write("Node km9 is the GPU box.")
        try:
            m = load(RUNBOOK_FILE=f.name, DIAGNOSIS_LANGUAGE="Russian")
            s = m.system_prompt()
            self.assertIn("Node km9 is the GPU box.", s)
            self.assertIn("Russian", s)
            self.assertIn("read-only", s)
        finally:
            os.unlink(f.name)

    def test_no_runbook_is_fine(self):
        self.assertNotIn("Runbook", load().system_prompt())


class Stub:
    """Local OpenAI/Ollama stub; records request paths and bodies."""

    def __init__(self, reply):
        self.reply, self.seen = reply, []
        stub = self

        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                stub.seen.append((self.path, json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
                b = json.dumps(stub.reply).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def log_message(self, *a):
                pass

        self.srv = HTTPServer(("127.0.0.1", 0), H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()


class AskLlmTest(unittest.TestCase):
    def test_openai_sends_system_and_user(self):
        stub = Stub({"choices": [{"message": {"content": " d "}}]})
        try:
            m = load(LLM_URL=f"http://127.0.0.1:{stub.port}/v1/", LLM_MAX_TOKENS="900")
            self.assertEqual(m.ask_llm("SYS", "USER"), "d")
            path, body = stub.seen[-1]
            self.assertEqual(path, "/v1/chat/completions")
            self.assertEqual(body["messages"], [{"role": "system", "content": "SYS"}, {"role": "user", "content": "USER"}])
            self.assertEqual(body["max_tokens"], 900)
            self.assertEqual(body["chat_template_kwargs"], {"enable_thinking": False})
        finally:
            stub.close()

    def test_ollama_sends_system_field(self):
        stub = Stub({"response": " d "})
        try:
            m = load(LLM_API="ollama", LLM_URL=f"http://127.0.0.1:{stub.port}")
            self.assertEqual(m.ask_llm("SYS", "USER"), "d")
            path, body = stub.seen[-1]
            self.assertEqual(path, "/api/generate")
            self.assertEqual((body["system"], body["prompt"], body["think"]), ("SYS", "USER", False))
        finally:
            stub.close()

    def test_empty_url_means_shared_ollama(self):
        self.assertEqual(load(LLM_API="ollama", LLM_URL="").LLM_URL, "http://ollama.platform.svc.cluster.local:11434")


class HandleGroupTest(unittest.TestCase):
    def setUp(self):
        self.m = load()
        self.m.query_victorialogs = lambda q, limit: [rec("2026-10-25T15:00:00Z", f"log for {q[-40:]}")]
        self.m.pod_context = lambda ns, pod, nodes: f"pod {ns}/{pod}: Running"
        self.m.fetch_active_alerts = lambda: []
        self.prompts = []

    def alert(self, pod, status="firing"):
        return {"status": status, "fingerprint": pod,
                "labels": {"alertname": "critical-log-pattern", "src_namespace": "ns", "src_pod": pod},
                "annotations": {"summary": f"errors from {pod}", "description": "what it means",
                                "logsql_query": "_time:10m panic | stats count() as n"}}

    def test_one_mail_one_llm_call_for_the_whole_group(self):
        self.m.ask_llm = lambda s, p: (self.prompts.append(p), "diag")[1]
        self.m.handle_group({"alerts": [self.alert("a"), self.alert("b"), self.alert("c", "resolved")]})
        self.assertEqual(len(self.prompts), 1)
        self.assertIn("errors from a", self.prompts[0])
        self.assertIn("errors from b", self.prompts[0])
        self.assertNotIn("errors from c", self.prompts[0])
        self.assertIn("what it means", self.prompts[0])
        self.assertEqual(len(self.m.sent), 1)
        subject, body = self.m.sent[0]
        self.assertIn("critical-log-pattern", subject)
        self.assertIn("(2)", subject)
        self.assertIn("diag", body)
        self.assertIn("pod ns/a: Running", body)

    def test_only_resolved_sends_nothing(self):
        self.m.ask_llm = lambda s, p: "diag"
        self.m.handle_group({"alerts": [self.alert("a", "resolved")]})
        self.assertEqual(self.m.sent, [])

    def test_llm_failure_still_mails(self):
        def boom(s, p):
            raise AttributeError("'NoneType' object has no attribute 'get'")
        self.m.ask_llm = boom
        self.m.handle_group({"alerts": [self.alert("a")]})
        self.assertIn("LLM diagnosis unavailable", self.m.sent[0][1])

    def test_context_failures_still_mail(self):
        def fail(*a):
            raise urllib.error.URLError("down")
        self.m.query_victorialogs = fail
        self.m.fetch_active_alerts = fail
        self.m.ask_llm = lambda s, p: "diag"
        self.m.handle_group({"alerts": [self.alert("a")]})
        self.assertEqual(len(self.m.sent), 1)


class PushTest(unittest.TestCase):
    def payload(self, severity="critical"):
        return {"alerts": [{"status": "firing", "fingerprint": "a",
                            "labels": {"alertname": "sip-registration-drop", "severity": severity},
                            "annotations": {"summary": "re-registration failing"}}]}

    def test_push_is_ntfy_json_to_server_root(self):
        stub = Stub({"id": "x"})
        try:
            m = load(PUSH_URL=f"http://127.0.0.1:{stub.port}/secret-topic?template=alertmanager")
            m.fetch_active_alerts = lambda: []
            m.ask_llm = lambda s, p: "Причина: " + "я" * 5000
            m.handle_group(self.payload())
            path, body = stub.seen[-1]
            self.assertEqual(path, "/")
            self.assertEqual(body["topic"], "secret-topic")
            self.assertIn("sip-registration-drop", body["title"])
            self.assertTrue(body["message"].startswith("Причина: "))
            self.assertLessEqual(len(body["message"].encode()), 3500)
            self.assertEqual(body["priority"], 4)
            self.assertEqual(len(m.sent), 1)
        finally:
            stub.close()

    def test_push_failure_does_not_stop_mail(self):
        m = load(PUSH_URL="http://127.0.0.1:1/topic")
        m.fetch_active_alerts = lambda: []
        m.ask_llm = lambda s, p: "diag"
        m.handle_group(self.payload("warning"))
        self.assertEqual(len(m.sent), 1)

    def test_no_push_url_no_push(self):
        m = load(PUSH_URL="")
        self.assertIsNone(m.push_notification("t", "msg", "warning"))


SECRETS = {
    "password=hunter2xyz": "hunter2xyz",
    'DB_PASSWORD: "s3cr3t-value"': "s3cr3t-value",
    '{"api_key": "abc123def456ghi"}': "abc123def456ghi",
    "Authorization: Bearer abcDEF123456ghiJKL": "abcDEF123456ghiJKL",
    "connecting to postgres://app:Sup3rS3cret@db:5432/app": "Sup3rS3cret",
    "redis://:QWErty123456@valkey:6379": "QWErty123456",
    "token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlX2hlcmU": "eyJzdWIiOiIxIn0",
    "using key ghp_abcdefghijklmnopqrstuvwxyz0123456789": "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
    "aws AKIAIOSFODNN7EXAMPLE configured": "AKIAIOSFODNN7EXAMPLE",
    "GET /callback?code=xyz&access_token=Zm9vYmFyYmF6cXV4 HTTP/1.1": "Zm9vYmFyYmF6cXV4",
    "secret QmFzZTY0U2VjcmV0VmFsdWVXaXRoTWl4ZWRDYXNlMTIz leaked": "QmFzZTY0U2VjcmV0VmFsdWVXaXRoTWl4ZWRDYXNlMTIz",
    "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA7\n-----END RSA PRIVATE KEY-----": "MIIEowIBAAKCAQEA7",
}


class RedactTest(unittest.TestCase):
    def test_secrets_masked(self):
        m = load()
        for text, secret in SECRETS.items():
            out = m.redact(text)
            self.assertNotIn(secret, out, text)

    def test_ordinary_lines_untouched(self):
        m = load()
        for text in [
            "pod linstor-controller-847c8b9bbb-5gs26 exit status 143",
            "image sha256:dcdf2718eb84421502fe1b2d4368259bcd1ebb8e85326c455d930a7e98ed62a6",
            "SETUSER phost-paseka-co-prod failed: Could not connect to Redis at redis-valkey-node-0:6379",
            "token bucket refilled, 5 tokens left",
            "password authentication failed for user \"app\"",
        ]:
            self.assertEqual(m.redact(text), text)

    def test_secret_in_logs_reaches_neither_prompt_nor_mail_nor_push(self):
        stub = Stub({"id": "x"})
        try:
            m = load(PUSH_URL=f"http://127.0.0.1:{stub.port}/topic")
            m.query_victorialogs = lambda q, limit: [rec("2026-10-25T15:00:00Z", "login with password=hunter2xyz failed")]
            m.fetch_active_alerts = lambda: []
            prompts = []
            # A model that echoes a secret it saw must not leak it either.
            m.ask_llm = lambda s, p: (prompts.append(p), "the log shows token=leakedTOKEN123456")[1]
            m.handle_group({"alerts": [{"status": "firing", "fingerprint": "a",
                                        "labels": {"alertname": "x", "severity": "warning"},
                                        "annotations": {"summary": "s", "logsql_query": "_time:10m fail"}}]})
            self.assertNotIn("hunter2xyz", prompts[0])
            self.assertNotIn("hunter2xyz", m.sent[0][1])
            self.assertNotIn("leakedTOKEN123456", m.sent[0][1])
            self.assertNotIn("leakedTOKEN123456", stub.seen[-1][1]["message"])
        finally:
            stub.close()


class PodContextTest(unittest.TestCase):
    def test_deleted_pod_shows_its_replacements(self):
        m = load()
        pods = {"items": [
            {"metadata": {"name": "linstor-controller-847c8b9bbb-x9x9x", "creationTimestamp": "2026-10-25T07:08:00Z"},
             "spec": {"nodeName": "n2"},
             "status": {"phase": "Running", "containerStatuses": [{"name": "c", "ready": True, "restartCount": 0, "state": {"running": {}}}]}},
            {"metadata": {"name": "other-1", "creationTimestamp": "2026-10-25T07:08:00Z"}, "spec": {}, "status": {}},
        ]}

        def get(path):
            if path.endswith("/pods/linstor-controller-847c8b9bbb-5gs26"):
                raise urllib.error.HTTPError(path, 404, "Not Found", {}, None)
            if path.endswith("/pods"):
                return pods
            if "/events" in path:
                return {"items": []}
            if path.startswith("/api/v1/nodes/"):
                return {"metadata": {"labels": {}}, "spec": {}, "status": {"conditions": [{"type": "Ready", "status": "True"}]}}
            raise AssertionError(path)

        m._k8s_get = get
        out = m.pod_context("piraeus-datastore", "linstor-controller-847c8b9bbb-5gs26", {})
        self.assertIn("no longer exists", out)
        self.assertIn("linstor-controller-847c8b9bbb-x9x9x", out)
        self.assertIn("n2", out)
        self.assertNotIn("other-1", out)


if __name__ == "__main__":
    unittest.main()
