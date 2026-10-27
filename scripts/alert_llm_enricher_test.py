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
    mod.sent, mod.sent_extra = [], []
    mod.send_email = lambda subject, body, **kw: (mod.sent.append((subject, body)), mod.sent_extra.append(kw))
    return mod


def rec(t, msg):
    return {"_time": t, "_msg": msg}


class CompressLinesTest(unittest.TestCase):
    def setUp(self):
        self.m = load()

    def test_repeats_fold_into_their_latest_occurrence(self):
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
                "15:32:00 other",
                "15:33:09 SETUSER a failed: connect 10.0.0.3:6379  [x3 since 15:31:14]",
            ],
        )

    def test_distinct_codes_and_ports_are_not_folded(self):
        out = self.m.compress_lines(
            [rec("2026-10-25T15:00:00Z", "exited with code 1"), rec("2026-10-25T15:00:01Z", "exited with code 137"),
             rec("2026-10-25T15:00:02Z", "dial db:5432 refused"), rec("2026-10-25T15:00:03Z", "dial db:6379 refused")],
            50,
        )
        self.assertEqual(len(out), 4)

    def test_recurring_error_survives_the_cut(self):
        recs = [rec("2026-10-25T15:00:00Z", "BOOM")]
        recs += [rec(f"2026-10-25T15:01:{i:02d}Z", f"ctx-{chr(97 + i)}") for i in range(10)]
        recs += [rec("2026-10-25T15:02:00Z", "BOOM")]
        out = self.m.compress_lines(recs, 3)
        self.assertEqual(out[-1], "15:02:00 BOOM  [x2 since 15:00:00]")

    def test_private_key_split_over_records_is_masked(self):
        out = self.m.compress_lines(
            [rec("2026-10-25T15:00:00Z", "-----BEGIN PRIVATE KEY-----"),
             rec("2026-10-25T15:00:00Z", "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC"),
             rec("2026-10-25T15:00:00Z", "abcdefghij0123456789"),
             rec("2026-10-25T15:00:00Z", "-----END PRIVATE KEY-----"),
             rec("2026-10-25T15:00:01Z", "after")],
            50,
        )
        joined = "\n".join(out)
        self.assertNotIn("MIIEvQ", joined)
        self.assertNotIn("abcdefghij0123456789", joined)
        self.assertIn("after", joined)

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

    def test_unknown_start_is_not_long_standing_and_none_fingerprint_kept(self):
        m = load()
        out = m.active_alerts_section(
            [{"startsAt": "garbage", "labels": {"alertname": "NodeDown"}, "annotations": {"summary": "s"}}],
            exclude={None},
        )
        self.assertIn("NodeDown", out)
        self.assertNotIn("Long-standing", out)


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


class BudgetWithSystemTest(unittest.TestCase):
    def test_system_prompt_counts_against_budget(self):
        m = load(PROMPT_CHAR_BUDGET="5000")
        ctx = [{"header": "a", "k8s": "", "logs": [f"line {j} " + "x" * 50 for j in range(200)]}]
        prompt = m.build_prompt("grp", ctx, "c", system_chars=3000)
        self.assertLessEqual(len(prompt), 2000)
        self.assertIn("line 199 ", prompt)


class LanguageTest(unittest.TestCase):
    def test_prompt_ends_with_the_language_instruction(self):
        m = load(DIAGNOSIS_LANGUAGE="Russian")
        prompt = m.build_prompt("grp", [{"header": "a", "k8s": "", "logs": ["x"]}], "c")
        last = prompt.strip().splitlines()[-1]
        self.assertIn("Russian", last)
        self.assertIn("headings", last)

    def test_system_prompt_forbids_write_commands(self):
        s = " ".join(load().system_prompt().split())
        self.assertIn("no delete, patch, edit, apply, restart, scale, exec, run, debug or cp", s)

    def test_language_line_survives_an_over_budget_prompt(self):
        m = load(PROMPT_CHAR_BUDGET="1500", DIAGNOSIS_LANGUAGE="Russian")
        prompt = m.build_prompt("grp", [{"header": "h" * 5000, "k8s": "", "logs": []}], "c")
        self.assertLessEqual(len(prompt), 1500)
        self.assertIn("Russian", prompt.strip().splitlines()[-1])


class SystemPromptTest(unittest.TestCase):
    def test_runbook_appended_when_present(self):
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
            f.write("Node gpu-a holds the GPUs.")
        try:
            m = load(RUNBOOK_FILE=f.name, DIAGNOSIS_LANGUAGE="Russian")
            s = m.system_prompt()
            self.assertIn("Node gpu-a holds the GPUs.", s)
            self.assertIn("Russian", s)
            self.assertIn("read-only", s)
        finally:
            os.unlink(f.name)

    def test_no_runbook_is_fine(self):
        self.assertNotIn("Runbook", load().system_prompt())


class Stub:
    """Local OpenAI/Ollama stub; records request paths, bodies and body sizes."""

    def __init__(self, reply):
        self.reply, self.seen, self.sizes = reply, [], []
        stub = self

        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                stub.sizes.append(len(raw))
                stub.seen.append((self.path, json.loads(raw)))
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
            self.assertEqual(body["temperature"], 0.2)
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
            self.assertEqual(body["options"]["temperature"], 0.2)
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

    def test_empty_answer_is_a_failure(self):
        self.m.ask_llm = lambda s, p: "   "
        self.m.handle_group({"alerts": [self.alert("a")]})
        self.assertIn("LLM diagnosis unavailable", self.m.sent[0][1])

    def test_smtp_failure_retries_and_still_pushes(self):
        calls, pushes = [], []

        def flaky(subject, body):
            calls.append(subject)
            raise OSError("smtp down")
        self.m.send_email = flaky
        self.m.SMTP_RETRY_DELAYS = (0, 0)
        self.m.push_notification = lambda title, msg, sev: pushes.append(title)
        self.m.ask_llm = lambda s, p: "diag"
        self.m.handle_group({"alerts": [self.alert("a")]})
        self.assertEqual(len(calls), 3)
        self.assertEqual(len(pushes), 1)

    def test_push_title_redacted(self):
        titles = []
        self.m.push_notification = lambda title, msg, sev: titles.append(title)
        self.m.ask_llm = lambda s, p: "diag"
        a = self.alert("a")
        a["labels"]["alertname"] = "x password=hunter2xyz"
        self.m.handle_group({"alerts": [a]})
        self.assertNotIn("hunter2xyz", titles[0])

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

    def test_push_body_fits_ntfy_json_limit(self):
        # ntfy rejects a JSON publish over twice its 4 KiB message limit (413);
        # \uXXXX escapes made a Cyrillic answer three times its UTF-8 size.
        stub = Stub({"id": "x"})
        try:
            m = load(PUSH_URL=f"http://127.0.0.1:{stub.port}/topic")
            m.push_notification("Пул на паузе (1)", "Причина: " + "я" * 5000, "critical")
            self.assertLessEqual(stub.sizes[-1], 8192)
            self.assertTrue(stub.seen[-1][1]["message"].startswith("Причина: я"))
        finally:
            stub.close()

    def test_push_body_fits_ntfy_json_limit_whatever_the_text(self):
        # JSON escapes quotes and newlines to 2 bytes, control characters to 6.
        stub = Stub({"id": "x"})
        try:
            m = load(PUSH_URL=f"http://127.0.0.1:{stub.port}/topic")
            for title, msg in [("t", "\x01" * 5000), ("t", '"\n' * 3000), ("x" * 5000, "short")]:
                m.push_notification(title, msg, "warning")
                self.assertLessEqual(stub.sizes[-1], 8192)
                self.assertEqual(stub.seen[-1][1]["topic"], "topic")
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
    'password="correct horse battery staple"': "horse battery staple",
    "api_key = 'my secret phrase'": "secret phrase",
    "postgres://app:pa/ss@word@db:5432/app": "ss@word",
    "run --password hunter2xyz --verbose": "hunter2xyz",
    "login user=admin pass=s3cretz": "s3cretz",
    "password=abc,defghij": "defghij",
}


class RedactTest(unittest.TestCase):
    def test_secrets_masked(self):
        m = load()
        for text, secret in SECRETS.items():
            out = m.redact(text)
            self.assertNotIn(secret, out, text)

    def test_push_topic_masked(self):
        m = load(PUSH_URL="https://ntfy.example/very-private-topic-123?template=alertmanager")
        out = m.redact("posting to https://ntfy.example/very-private-topic-123 failed; topic very-private-topic-123")
        self.assertNotIn("very-private-topic-123", out)

    def test_ordinary_lines_untouched(self):
        m = load()
        for text in [
            "pod linstor-controller-847c8b9bbb-5gs26 exit status 143",
            "image sha256:dcdf2718eb84421502fe1b2d4368259bcd1ebb8e85326c455d930a7e98ed62a6",
            "SETUSER phost-example-org-prod failed: Could not connect to Redis at redis-valkey-node-0:6379",
            "token bucket refilled, 5 tokens left",
            "password authentication failed for user \"app\"",
            "owner=ReplicaSet/redis-acl-keeper-768485dbfc",
            "Deployment/MyServiceController-backend-7f9c6d5b8a-x2x9q",
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


class NodeSummaryTest(unittest.TestCase):
    def test_forbidden_is_not_reported_as_powered_off(self):
        m = load()

        def get(path):
            raise urllib.error.HTTPError(path, 403, "Forbidden", {}, None)
        m._k8s_get = get
        out = m.node_summary("n1", {})
        self.assertIn("403", out)
        self.assertNotIn("powered off", out)

    def test_missing_node_is_reported_as_gone(self):
        m = load()

        def get(path):
            raise urllib.error.HTTPError(path, 404, "Not Found", {}, None)
        m._k8s_get = get
        self.assertIn("not registered", m.node_summary("n1", {}))


class PodContextTest(unittest.TestCase):
    def test_deleted_pod_shows_its_replacements(self):
        m = load()
        pods = {"items": [
            {"metadata": {"name": "linstor-controller-847c8b9bbb-x9x9x", "creationTimestamp": "2026-10-25T07:08:00Z",
                          "ownerReferences": [{"kind": "ReplicaSet", "name": "linstor-controller-847c8b9bbb"}]},
             "spec": {"nodeName": "n2"},
             "status": {"phase": "Running", "containerStatuses": [{"name": "c", "ready": True, "restartCount": 0, "state": {"running": {}}}]}},
            {"metadata": {"name": "other-1", "creationTimestamp": "2026-10-25T07:08:00Z"}, "spec": {}, "status": {}},
            {"metadata": {"name": "linstor-controller-847c8b9bbb-canary", "creationTimestamp": "2026-10-25T07:08:00Z",
                          "ownerReferences": [{"kind": "ReplicaSet", "name": "linstor-controller-847c8b9bbb-canary"}]},
             "spec": {}, "status": {}},
            {"metadata": {"name": "linstor-controller-5d4c3b2a19-newpo", "creationTimestamp": "2026-10-25T08:00:00Z",
                          "ownerReferences": [{"kind": "ReplicaSet", "name": "linstor-controller-5d4c3b2a19"}]},
             "spec": {"nodeName": "n3"}, "status": {"phase": "Running"}},
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
        self.assertNotIn("canary", out)
        self.assertIn("linstor-controller-5d4c3b2a19-newpo", out)

    def test_warning_events_filtered_before_the_newest_ten(self):
        m = load()
        items = [{"type": "Normal", "reason": "Pulled", "lastTimestamp": f"2026-10-25T10:{i:02d}:00Z"} for i in range(12)]
        items.append({"type": "Warning", "reason": "FailedMount", "message": "m", "lastTimestamp": "2026-10-25T09:00:00Z"})
        m._k8s_get = lambda path: {"items": items}
        self.assertIn("FailedMount", m.query_pod_events("ns", "p"))


def vreport(ns, kind, name, repo, tag, vulns, server="quay.io"):
    return {
        "metadata": {"labels": {"trivy-operator.resource.namespace": ns, "trivy-operator.resource.kind": kind,
                                "trivy-operator.resource.name": name}},
        "report": {"registry": {"server": server}, "artifact": {"repository": repo, "tag": tag},
                   "vulnerabilities": vulns},
    }


def vuln(cve, severity="CRITICAL", pkg="openssl", score=9.8):
    return {"vulnerabilityID": cve, "severity": severity, "resource": pkg, "installedVersion": "1.0",
            "fixedVersion": "1.1", "score": score, "title": f"{pkg} hole"}


class CollectFindingsTest(unittest.TestCase):
    def test_groups_by_image_and_drops_other_severities(self):
        m = load()
        out = m.collect_findings(
            [
                vreport("a", "StatefulSet", "db", "org/db", "v1.2.3", [vuln("CVE-1"), vuln("CVE-2", "HIGH")]),
                vreport("b", "DaemonSet", "db2", "org/db", "v1.2.3", [vuln("CVE-1")]),
                vreport("c", "StatefulSet", "web", "org/web", "1.0", [vuln("CVE-3", "HIGH")]),
            ],
            set(),
        )
        self.assertEqual(list(out), ["quay.io/org/db:v1.2.3"])
        img = out["quay.io/org/db:v1.2.3"]
        self.assertEqual(set(img["cves"]), {"CVE-1"})
        self.assertEqual(img["workloads"], {"a/StatefulSet/db", "b/DaemonSet/db2"})
        self.assertEqual((img["registry"], img["repository"], img["tag"]), ("quay.io", "org/db", "v1.2.3"))

    def test_replicaset_without_pods_is_a_stale_report(self):
        m = load()
        reports = [
            vreport("a", "ReplicaSet", "app-old", "org/app", "v1", [vuln("CVE-1")]),
            vreport("a", "ReplicaSet", "app-new", "org/app", "v2", [vuln("CVE-1")]),
        ]
        self.assertEqual(list(m.collect_findings(reports, {"a/app-new"})), ["quay.io/org/app:v2"])

    def test_deployment_replicaset_shown_as_deployment(self):
        m = load()
        out = m.collect_findings([vreport("a", "ReplicaSet", "web-7f9c6d5b8c", "org/web", "v1", [vuln("CVE-1")])],
                                 {"a/web-7f9c6d5b8c"})
        self.assertEqual(out["quay.io/org/web:v1"]["workloads"], {"a/Deployment/web"})

    def test_active_replicasets_from_pod_owners(self):
        m = load()
        pods = [{"metadata": {"namespace": "a", "ownerReferences": [{"kind": "ReplicaSet", "name": "app-1"}]}},
                {"metadata": {"namespace": "a", "ownerReferences": [{"kind": "StatefulSet", "name": "db"}]}},
                {"metadata": {"namespace": "b"}}]
        self.assertEqual(m.active_replicasets(pods), {"a/app-1"})


class NewerTagTest(unittest.TestCase):
    def setUp(self):
        self.m = load()

    def test_patch_and_latest_of_the_same_flavour(self):
        tags = ["v1.2.3", "v1.2.5", "v1.3.0", "v1.4.0-rc1", "v1.9.0-alpine", "latest", "1.9.9"]
        self.assertEqual(self.m.newer_tag("v1.2.3", tags), "v1.2.5 (latest v1.3.0)")

    def test_two_part_tags_have_no_patch(self):
        self.assertEqual(self.m.newer_versions("3.20", ["3.21", "3.24"]), ("", "3.24"))

    def test_patch_is_latest(self):
        self.assertEqual(self.m.newer_tag("18.6-alpine", ["18.6-alpine", "18.7-alpine", "18.7"]), "18.7-alpine")

    def test_nothing_newer(self):
        self.assertEqual(self.m.newer_tag("v1.2.3", ["v1.2.3", "v1.2.2", "v1.3.0-rc1"]), "")

    def test_unversioned_tag(self):
        self.assertEqual(self.m.newer_tag("latest", ["v9"]), "")


class DigestDecisionTest(unittest.TestCase):
    NOW = 1_800_000_000

    def setUp(self):
        self.m = load(SECURITY_DIGEST_REMINDER_SECONDS="604800")

    def findings(self, tag="v1", cves=("CVE-1",)):
        return self.m.collect_findings([vreport("a", "StatefulSet", "s", "org/app", tag, [vuln(c) for c in cves])], set())

    def test_first_run_reports_everything(self):
        d = self.m.digest_decision(self.findings(), {}, {}, self.NOW)
        self.assertEqual(d["reason"], "change")
        self.assertEqual(d["new"], {"quay.io/org/app|CVE-1"})

    def test_nothing_changed_sends_nothing(self):
        f = self.findings()
        state = self.m.new_state(f, {}, self.NOW - 3600)
        self.assertIsNone(self.m.digest_decision(f, {}, state, self.NOW))

    def test_retag_with_the_same_cves_is_not_new(self):
        state = self.m.new_state(self.findings("v1"), {}, self.NOW - 3600)
        self.assertIsNone(self.m.digest_decision(self.findings("v2"), {}, state, self.NOW))

    def test_new_cve_and_fixed_cve(self):
        state = self.m.new_state(self.findings(cves=("CVE-1", "CVE-2")), {}, self.NOW - 3600)
        d = self.m.digest_decision(self.findings(cves=("CVE-1", "CVE-3")), {}, state, self.NOW)
        self.assertEqual(d["new"], {"quay.io/org/app|CVE-3"})
        self.assertEqual(d["fixed"], ["quay.io/org/app|CVE-2"])

    def test_cve_gone_alone_waits_for_the_next_digest(self):
        state = self.m.new_state(self.findings(cves=("CVE-1", "CVE-2")), {}, self.NOW - 3600)
        self.assertIsNone(self.m.digest_decision(self.findings(cves=("CVE-1",)), {}, state, self.NOW))

    def test_newly_available_tag_is_a_change(self):
        f = self.findings()
        state = self.m.new_state(f, {}, self.NOW - 3600)
        d = self.m.digest_decision(f, {"quay.io/org/app:v1": "v2"}, state, self.NOW)
        self.assertEqual((d["reason"], d["new_tags"]), ("change", {"quay.io/org/app:v1"}))
        state = self.m.new_state(f, {"quay.io/org/app:v1": "v2"}, self.NOW - 3600)
        self.assertIsNone(self.m.digest_decision(f, {"quay.io/org/app:v1": "v2"}, state, self.NOW))

    def test_weekly_reminder_only_for_pending_updates(self):
        f, newer = self.findings(), {"quay.io/org/app:v1": "v2"}
        week_ago = self.NOW - 604800
        self.assertEqual(self.m.digest_decision(f, newer, self.m.new_state(f, newer, week_ago), self.NOW)["reason"], "reminder")
        self.assertIsNone(self.m.digest_decision(f, newer, self.m.new_state(f, newer, week_ago + 60), self.NOW))
        self.assertIsNone(self.m.digest_decision(f, {}, self.m.new_state(f, {}, week_ago), self.NOW))




class InventoryTest(unittest.TestCase):
    def setUp(self):
        self.m = load()

    def test_parse_image(self):
        p = self.m.parse_image
        self.assertEqual(p("postgres:18.6-alpine"), ("docker.io", "library/postgres", "18.6-alpine"))
        self.assertEqual(p("docker.io/grafana/grafana:13.2.3"), ("docker.io", "grafana/grafana", "13.2.3"))
        self.assertEqual(p("quay.io/a/b:v1@sha256:abc"), ("quay.io", "a/b", "v1"))
        self.assertEqual(p("ghcr.io/o/r@sha256:abc"), ("ghcr.io", "o/r", ""))
        self.assertEqual(p("localhost:5000/x:1"), ("localhost:5000", "x", "1"))
        self.assertEqual(p("nginx"), ("docker.io", "library/nginx", "latest"))

    def test_rows_classify_every_running_image(self):
        def pod(ns, owner_kind, owner, *images):
            return {"metadata": {"namespace": ns, "name": f"{owner}-x", "ownerReferences": [{"kind": owner_kind, "name": owner}]},
                    "spec": {"containers": [{"name": f"c{i}", "image": im} for i, im in enumerate(images)]}}

        pods = [
            pod("a", "ReplicaSet", "web-7f9c6d5b8c", "quay.io/o/web:v1.0.0", "nginx:alpine"),
            pod("b", "StatefulSet", "db", "quay.io/o/web:v1.0.0@sha256:abc", "ghcr.io/o/app@sha256:def"),
            pod("c", "DaemonSet", "agent", "quay.io/o/agent:v2.0.0", "quay.io/o/gone:v1.0.0"),
        ]
        versions = {"o/web": ("v1.0.3", "v1.2.0"), "o/agent": ("", ""), "o/gone": None}
        self.m.lookup_versions = lambda registry, repository, tag: versions[repository]
        reports = [vreport("a", "ReplicaSet", "web-7f9c6d5b8c", "o/web", "v1.0.0", [vuln("CVE-1"), vuln("CVE-2", "HIGH")])]
        rows = {r["image"]: r for r in self.m.build_inventory(pods, reports)}
        web = rows["quay.io/o/web:v1.0.0"]
        self.assertEqual(web["status"], "patch available")
        self.assertEqual((web["patch"], web["latest"], web["critical"], web["high"]), ("v1.0.3", "v1.2.0", 1, 1))
        self.assertEqual(web["workloads"], ["a/Deployment/web", "b/StatefulSet/db"])
        self.assertEqual(web["pinned"], "partly")
        self.assertEqual(rows["docker.io/library/nginx:alpine"]["status"], "floating tag")
        self.assertEqual(rows["ghcr.io/o/app"]["status"], "digest only")
        self.assertEqual(rows["ghcr.io/o/app"]["pinned"], "yes")
        self.assertEqual(rows["quay.io/o/agent:v2.0.0"]["status"], "up to date")
        self.assertEqual(rows["quay.io/o/gone:v1.0.0"]["status"], "unknown")
        self.assertEqual(list(rows)[0], "quay.io/o/web:v1.0.0")


class XlsxTest(unittest.TestCase):
    def test_workbook_holds_every_sheet_and_escapes_text(self):
        m = load()
        data = m.xlsx_bytes([("Images", ["Image", "Critical"], [["a<b>&c", 3]], [None]),
                             ("Findings", ["CVE"], [["CVE-1"]], [None])])
        import io as _io
        import zipfile as _zip
        with _zip.ZipFile(_io.BytesIO(data)) as z:
            self.assertIsNone(z.testzip())
            workbook = z.read("xl/workbook.xml").decode()
            sheet = z.read("xl/worksheets/sheet1.xml").decode()
        self.assertIn('name="Images"', workbook)
        self.assertIn('name="Findings"', workbook)
        self.assertIn("a&lt;b&gt;&amp;c", sheet)
        self.assertIn("<v>3</v>", sheet)
        try:
            import openpyxl
        except ImportError:
            return
        wb = openpyxl.load_workbook(_io.BytesIO(data))
        self.assertEqual(wb["Images"]["A2"].value, "a<b>&c")
        self.assertEqual(wb["Images"]["B2"].value, 3)


class SecurityDigestRunTest(unittest.TestCase):
    def setUp(self):
        self.m = load()
        self.reports = [vreport("a", "StatefulSet", "s", "org/app", "v1", [vuln("CVE-1")])]
        self.m.fetch_vulnerability_reports = lambda: self.reports
        self.m.fetch_pods = lambda: []
        self.m.lookup_versions = lambda registry, repository, tag: ("v2", "v2")
        self.state = {}
        self.m.read_state = lambda: dict(self.state)
        self.m.write_state = lambda s: self.state.update(s)
        self.pushes, self.prompts = [], []
        self.m.push_notification = lambda title, message, severity: self.pushes.append((title, message))
        self.m.ask_llm = lambda s, p: (self.prompts.append((s, p)), "advice")[1]
        self.m.SMTP_RETRY_DELAYS = ()

    def test_sends_once_then_stays_quiet(self):
        self.m.run_security_digest(1_800_000_000)
        self.assertEqual(len(self.m.sent), 1)
        subject, body = self.m.sent[0]
        self.assertIn("Security digest", subject)
        self.assertIn("advice", body)
        self.assertIn("CVE-1", body)
        self.assertIn("v2", body)
        self.assertEqual(len(self.pushes), 1)
        extra = self.m.sent_extra[0]
        self.assertIn("CVE-1", extra["html_body"])
        self.assertIn("advice", extra["html_body"])
        self.assertTrue(extra["attachments"][0][0].endswith(".xlsx"))
        self.m.run_security_digest(1_800_003_600)
        self.assertEqual(len(self.m.sent), 1)

    def test_prompt_marks_new_and_carries_the_switch_off_rule(self):
        self.m.run_security_digest(1_800_000_000)
        system, prompt = self.prompts[0]
        self.assertIn("[NEW] CVE-1", prompt)
        self.assertIn("newer tag: v2", prompt)
        self.assertIn("non-critical", system)
        self.assertTrue(prompt.endswith(self.m._security_final_instruction()))

    def test_advice_is_escaped_in_html(self):
        self.m.ask_llm = lambda s, p: "<script>x</script>"
        self.m.run_security_digest(1_800_000_000)
        self.assertNotIn("<script>", self.m.sent_extra[0]["html_body"])

    def test_llm_failure_still_mails(self):
        def boom(s, p):
            raise OSError("down")
        self.m.ask_llm = boom
        self.m.run_security_digest(1_800_000_000)
        self.assertIn("unavailable", self.m.sent[0][1])
        self.assertIn("CVE-1", self.m.sent[0][1])

    def test_mail_failure_keeps_the_state_for_a_retry(self):
        def fail(subject, body, **kw):
            raise OSError("smtp down")
        self.m.send_email = fail
        self.m.run_security_digest(1_800_000_000)
        self.assertEqual(self.state, {})

    def test_unreadable_reports_send_nothing(self):
        def fail():
            raise OSError("api down")
        self.m.fetch_vulnerability_reports = fail
        self.m.run_security_digest(1_800_000_000)
        self.assertEqual(self.m.sent, [])
        self.assertEqual(self.state, {})


if __name__ == "__main__":
    unittest.main()
