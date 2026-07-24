"""End-to-end tests for the gateway (server.py): alias routing, cheap/any
failover, streaming passthrough, and the /control security gates.

Boots the real Handler on an ephemeral port against fake OpenAI backends —
everything is asserted through actual HTTP. Stdlib only, like the gateway.
Run: python3 -m unittest discover gateway/tests
"""

import http.client
import json
import os
import sys
import tempfile
import threading
import types
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

GATEWAY_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GATEWAY_DIR))

_TMP = tempfile.TemporaryDirectory(prefix="honeycomb-gw-test-")
TMP = Path(_TMP.name)

CONTROL_TOKEN = "test-token-8c1f2a"


class FakeBackend(BaseHTTPRequestHandler):
    """Minimal OpenAI-compatible upstream. Behavior is flipped per-test via
    attributes on the server object: healthy, mode ('ok'|'fail'), models."""

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            if not self.server.healthy:
                self._json(500, {"error": "unhealthy"})
                return
            self._json(
                200,
                {"object": "list", "data": [{"id": m} for m in self.server.models]},
            )
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        payload = json.loads(self.rfile.read(n).decode() or "{}")
        self.server.received.append({"path": self.path, "payload": payload})
        if self.server.mode == "fail":
            self._json(500, {"error": {"message": "upstream exploded"}})
            return
        if payload.get("stream"):
            body = (
                b'data: {"choices":[{"delta":{"content":"po"}}]}\n\n'
                b'data: {"choices":[{"delta":{"content":"ng"}}]}\n\n'
                b"data: [DONE]\n\n"
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._json(
            200,
            {
                "id": "cmpl-1",
                "object": "chat.completion",
                "model": payload.get("model"),
                "served_by": self.server.tag,
                "choices": [{"message": {"role": "assistant", "content": "pong"}}],
                "usage": {"prompt_tokens": 5, "completion_tokens": 2},
            },
        )

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def _start_backend(tag, models):
    srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeBackend)
    srv.tag = tag
    srv.models = models
    srv.healthy = True
    srv.mode = "ok"
    srv.received = []
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


ALPHA = _start_backend("alpha", ["alpha-embed-model", "alpha-chat"])
BETA = _start_backend("beta", ["beta-chat"])

_config = {
    "listen_host": "127.0.0.1",
    "listen_port": 4999,
    "default_model": "al",
    "control_token": CONTROL_TOKEN,
    "allowed_hosts": ["hub.tailnet.example"],
    "cheap_order": ["alpha", "beta"],
    "backends": {
        "alpha": {
            "name": "Alpha",
            "base_url": f"http://127.0.0.1:{ALPHA.server_address[1]}/v1",
        },
        "beta": {
            "name": "Beta",
            "base_url": f"http://127.0.0.1:{BETA.server_address[1]}/v1",
        },
    },
    "aliases": {
        "al": {"backend": "alpha", "upstream_model": "pinned-alpha-model"},
        "auto-al": {"backend": "alpha"},
        "bt": {"backend": "beta", "upstream_model": "beta-chat"},
    },
}
(TMP / "config.json").write_text(json.dumps(_config))
(TMP / "fleet.json").write_text(json.dumps({"title": "TEST", "nodes": [], "links": []}))

os.environ["HONEYCOMB_GATEWAY_CONFIG"] = str(TMP / "config.json")
os.environ["HONEYCOMB_FLEET"] = str(TMP / "fleet.json")

import server  # noqa: E402  (reads env at import)
import nodes as fleet_nodes  # noqa: E402

# Never touch the repo's real stats.json from tests.
server.STATS_PATH = TMP / "stats.json"
# Keep test output readable — the route/access log lines aren't assertions.
server.log = lambda *args: None

GATEWAY = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
threading.Thread(target=GATEWAY.serve_forever, daemon=True).start()
PORT = GATEWAY.server_address[1]
BASE = f"http://127.0.0.1:{PORT}"


def _clear_probe_cache():
    with server._probe_lock:
        server._probe_cache.clear()
        server._probe_refreshing.clear()


def _request(method, path, body=None, headers=None, timeout=15):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
    )
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers.items()), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers.items()), e.read()


class GatewayTestCase(unittest.TestCase):
    def setUp(self):
        for be in (ALPHA, BETA):
            be.healthy = True
            be.mode = "ok"
            be.received.clear()
        _clear_probe_cache()


class Routing(GatewayTestCase):
    def test_alias_routes_to_pinned_upstream_model(self):
        status, _, raw = _request(
            "POST", "/v1/chat/completions",
            {"model": "al", "messages": [{"role": "user", "content": "hi"}]},
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)["served_by"], "alpha")
        self.assertEqual(ALPHA.received[-1]["payload"]["model"], "pinned-alpha-model")

    def test_alias_without_upstream_picks_first_chat_model_skipping_embeds(self):
        status, _, _ = _request(
            "POST", "/v1/chat/completions", {"model": "auto-al", "messages": []}
        )
        self.assertEqual(status, 200)
        # alpha-embed-model sorts first upstream but must not be chosen
        self.assertEqual(ALPHA.received[-1]["payload"]["model"], "alpha-chat")

    def test_model_at_backend_passthrough(self):
        status, _, raw = _request(
            "POST", "/v1/chat/completions", {"model": "custom-x@beta", "messages": []}
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)["served_by"], "beta")
        self.assertEqual(BETA.received[-1]["payload"]["model"], "custom-x")

    def test_backend_slash_model_passthrough(self):
        status, _, raw = _request(
            "POST", "/v1/chat/completions", {"model": "beta/custom-y", "messages": []}
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)["served_by"], "beta")
        self.assertEqual(BETA.received[-1]["payload"]["model"], "custom-y")

    def test_default_model_used_when_none_given(self):
        status, _, raw = _request("POST", "/v1/chat/completions", {"messages": []})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)["served_by"], "alpha")
        self.assertEqual(ALPHA.received[-1]["payload"]["model"], "pinned-alpha-model")

    def test_embeddings_path_proxied(self):
        status, _, _ = _request(
            "POST", "/v1/embeddings", {"model": "al", "input": "x"}
        )
        self.assertEqual(status, 200)
        self.assertEqual(ALPHA.received[-1]["path"], "/v1/embeddings")


class CheapAndFailover(GatewayTestCase):
    def test_cheap_resolves_to_first_healthy_backend(self):
        status, _, raw = _request(
            "POST", "/v1/chat/completions", {"model": "cheap", "messages": []}
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)["served_by"], "alpha")
        self.assertEqual(ALPHA.received[-1]["payload"]["model"], "alpha-chat")

    def test_cheap_skips_unhealthy_backend(self):
        ALPHA.healthy = False
        _clear_probe_cache()
        status, _, raw = _request(
            "POST", "/v1/chat/completions", {"model": "cheap", "messages": []}
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)["served_by"], "beta")

    def test_any_fails_over_to_next_backend_on_500(self):
        ALPHA.mode = "fail"  # healthy /models, exploding /chat/completions
        status, _, raw = _request(
            "POST", "/v1/chat/completions", {"model": "any", "messages": []}
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)["served_by"], "beta")
        # both backends were actually attempted
        self.assertEqual(len(ALPHA.received), 1)
        self.assertEqual(len(BETA.received), 1)

    def test_failover_flag_enables_retry_and_is_stripped(self):
        ALPHA.mode = "fail"
        status, _, raw = _request(
            "POST", "/v1/chat/completions",
            {"model": "al", "failover": True, "messages": []},
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)["served_by"], "beta")
        # the private flag must never reach an upstream API
        for be in (ALPHA, BETA):
            for r in be.received:
                self.assertNotIn("failover", r["payload"])

    def test_upstream_500_passes_through_without_failover(self):
        BETA.mode = "fail"
        status, _, _ = _request(
            "POST", "/v1/chat/completions", {"model": "bt", "messages": []}
        )
        self.assertEqual(status, 500)
        self.assertEqual(len(ALPHA.received), 0)  # no silent retry elsewhere

    def test_unhealthy_backend_502_backend_down(self):
        BETA.healthy = False
        _clear_probe_cache()
        status, _, raw = _request(
            "POST", "/v1/chat/completions", {"model": "beta", "messages": []}
        )
        self.assertEqual(status, 502)
        self.assertEqual(json.loads(raw)["error"]["type"], "backend_down")


class Streaming(GatewayTestCase):
    def test_sse_chunks_pass_through(self):
        status, headers, raw = _request(
            "POST", "/v1/chat/completions",
            {"model": "al", "stream": True, "messages": []},
        )
        self.assertEqual(status, 200)
        self.assertIn("text/event-stream", headers.get("Content-Type", ""))
        text = raw.decode()
        self.assertIn('"content":"po"', text)
        self.assertIn("data: [DONE]", text)
        self.assertTrue(ALPHA.received[-1]["payload"]["stream"])


class ModelsListing(GatewayTestCase):
    def test_merge_models_lists_dynamic_aliases_and_upstreams(self):
        status, _, raw = _request("GET", "/v1/models")
        self.assertEqual(status, 200)
        ids = {m["id"] for m in json.loads(raw)["data"]}
        for expected in ("cheap", "any", "al", "bt", "alpha/alpha-chat", "beta/beta-chat"):
            self.assertIn(expected, ids)


class RequestValidation(GatewayTestCase):
    def test_invalid_json_400(self):
        req = urllib.request.Request(
            BASE + "/v1/chat/completions", data=b"{not json", method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                status = resp.status
        except urllib.error.HTTPError as e:
            status = e.code
        self.assertEqual(status, 400)

    def test_oversized_body_413(self):
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
        conn.putrequest("POST", "/v1/chat/completions")
        conn.putheader("Content-Length", str(64 * 1024 * 1024))
        conn.endheaders()
        resp = conn.getresponse()
        self.assertEqual(resp.status, 413)
        conn.close()

    def test_unknown_path_404(self):
        status, _, _ = _request("GET", "/nope")
        self.assertEqual(status, 404)


class ControlSecurity(GatewayTestCase):
    """The security model (CLAUDE.md: don't weaken). Every rule pinned."""

    def test_localhost_with_literal_host_is_exempt_from_token(self):
        status, _, raw = _request("POST", "/control/ping", {"node": "nope"})
        self.assertEqual(status, 200)  # authorized; unknown node is an app error
        self.assertFalse(json.loads(raw)["ok"])

    def test_dns_rebinding_host_denied_even_from_localhost(self):
        status, _, _ = _request(
            "POST", "/control/ping", {"node": "nope"},
            headers={"Host": "evil.example.com"},
        )
        self.assertEqual(status, 401)

    def test_allowed_host_name_is_accepted(self):
        status, _, _ = _request(
            "POST", "/control/ping", {"node": "nope"},
            headers={"Host": "hub.tailnet.example"},
        )
        self.assertEqual(status, 200)

    def test_control_responses_carry_no_cors(self):
        _, headers, _ = _request("POST", "/control/ping", {"node": "nope"})
        self.assertNotIn("Access-Control-Allow-Origin", headers)
        _, headers, _ = _request(
            "POST", "/control/ping", {"node": "nope"},
            headers={"Host": "evil.example.com"},
        )
        self.assertNotIn("Access-Control-Allow-Origin", headers)

    def test_api_responses_do_carry_cors(self):
        _, headers, _ = _request("GET", "/v1/models")
        self.assertEqual(headers.get("Access-Control-Allow-Origin"), "*")

    def test_unknown_control_action_404(self):
        status, _, _ = _request("POST", "/control/reboot-the-moon", {"node": "x"})
        self.assertEqual(status, 404)

    def test_token_validation_rules(self):
        def fake(supplied):
            return types.SimpleNamespace(
                headers={"X-Honeycomb-Token": supplied} if supplied else {}
            )

        valid = server.Handler._token_valid
        self.assertTrue(valid(fake(CONTROL_TOKEN)))
        self.assertFalse(valid(fake("wrong-token")))
        self.assertFalse(valid(fake(None)))
        # Placeholder tokens from the example config never authorize,
        # even when the client supplies the matching value.
        original = server.CFG["control_token"]
        try:
            server.CFG["control_token"] = "__REPLACE_ME__"
            self.assertFalse(valid(fake("__REPLACE_ME__")))
            server.CFG["control_token"] = ""
            self.assertFalse(valid(fake("")))
        finally:
            server.CFG["control_token"] = original

    def test_nodes_doctor_report_redacted_for_unauthorized_callers(self):
        with fleet_nodes._lock:
            fleet_nodes._fleet = {
                "title": "TEST",
                "nodes": [{"id": "n1", "name": "n1", "axial": [0, 0]}],
                "links": [],
            }
            fleet_nodes._doctor["n1"] = {"ts": 1.0, "findings": [], "error": None}
        try:
            _, _, raw = _request("GET", "/nodes")
            self.assertIsNotNone(json.loads(raw)["nodes"][0]["doctor"])
            _, _, raw = _request(
                "GET", "/nodes", headers={"Host": "evil.example.com"}
            )
            self.assertIsNone(json.loads(raw)["nodes"][0]["doctor"])
        finally:
            with fleet_nodes._lock:
                fleet_nodes._fleet = {"title": "TEST", "nodes": [], "links": []}
                fleet_nodes._doctor.clear()


class HealthEndpoint(GatewayTestCase):
    def test_health_reports_backends_and_cheap_resolution(self):
        status, _, raw = _request("GET", "/health")
        self.assertEqual(status, 200)
        data = json.loads(raw)
        self.assertEqual(data["status"], "ok")
        self.assertTrue(data["backends"]["alpha"]["healthy"])
        self.assertEqual(
            data["cheap"]["resolves_to"],
            {"backend": "alpha", "model": "alpha-chat"},
        )


if __name__ == "__main__":
    unittest.main()
