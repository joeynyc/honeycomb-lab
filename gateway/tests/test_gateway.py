"""End-to-end tests for the gateway (server.py): alias routing, cheap/any
failover, streaming passthrough, and the /control security gates.

Boots the real Handler on an ephemeral port against fake OpenAI backends —
everything is asserted through actual HTTP. Stdlib only, like the gateway.
Run: python3 -m unittest discover gateway/tests
"""

import atexit
import http.client
import json
import os
import sys
import tempfile
import threading
import time
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
        if payload.get("stream") and self.server.mode == "truncate_stream":
            # Advertise more data than is sent so urllib raises IncompleteRead
            # while the gateway is reading an already-started upstream stream.
            body = b'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n'
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body) + 8192))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            self.close_connection = True
            return
        if payload.get("stream") and self.server.mode == "slow_stream":
            # Keep producing full proxy-sized chunks long enough for a client
            # disconnect to reach the gateway's downstream write path.
            chunk = b"data: " + (b"x" * 4088) + b"\n\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            try:
                for _ in range(200):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    time.sleep(0.01)
            except (BrokenPipeError, ConnectionResetError):
                pass
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


def _cleanup_test_resources():
    for srv in (GATEWAY, ALPHA, BETA):
        srv.shutdown()
        srv.server_close()
    _TMP.cleanup()


atexit.register(_cleanup_test_resources)


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
        try:
            return e.code, dict(e.headers.items()), e.read()
        finally:
            e.close()


def _wait_for_requests(count, timeout=2.0):
    """Poll the public history endpoint until async request recording catches up."""
    deadline = time.monotonic() + timeout
    entries = []
    while time.monotonic() < deadline:
        _, _, raw = _request("GET", "/requests")
        entries = json.loads(raw)["requests"]
        if len(entries) >= count:
            return entries
        time.sleep(0.01)
    return entries


def _wait_for_stat(key, request_count=1, timeout=2.0):
    """Poll the public health endpoint until cumulative stats catch up."""
    deadline = time.monotonic() + timeout
    stat = None
    while time.monotonic() < deadline:
        _, _, raw = _request("GET", "/health")
        stat = json.loads(raw)["stats"].get(key)
        if stat and stat["requests"] >= request_count:
            return stat
        time.sleep(0.01)
    return stat


class GatewayTestCase(unittest.TestCase):
    def setUp(self):
        for be in (ALPHA, BETA):
            be.healthy = True
            be.mode = "ok"
            be.received.clear()
        _clear_probe_cache()
        # Isolate request history / cumulative stats between tests.
        with server._requests_lock:
            server._request_log.clear()
        with server._stats_lock:
            server._stats.clear()


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

    def test_successful_stream_not_counted_as_error(self):
        """Completed SSE streams must land in history/stats as success, not error.

        Regression: record_request used status=None for streams, and
        _update_stats treats None as an error.
        """
        status, _, raw = _request(
            "POST", "/v1/chat/completions",
            {"model": "al", "stream": True, "messages": []},
        )
        self.assertEqual(status, 200)
        self.assertIn("data: [DONE]", raw.decode())

        _, _, hist_raw = _request("GET", "/requests")
        entries = json.loads(hist_raw)["requests"]
        self.assertEqual(len(entries), 1)
        entry = entries[0]
        self.assertTrue(entry["stream"])
        self.assertEqual(entry["status"], 200)
        self.assertEqual(entry["alias"], "al")
        self.assertEqual(entry["backend"], "alpha")

        _, _, health_raw = _request("GET", "/health")
        stats = json.loads(health_raw)["stats"]
        self.assertIn("al", stats)
        self.assertEqual(stats["al"]["requests"], 1)
        self.assertEqual(stats["al"]["errors"], 0)

    def test_stream_upstream_http_error_counted(self):
        ALPHA.mode = "fail"
        status, _, _ = _request(
            "POST", "/v1/chat/completions",
            {"model": "al", "stream": True, "messages": []},
        )
        self.assertEqual(status, 500)

        entries = _wait_for_requests(1)
        self.assertEqual(len(entries), 1)
        self.assertTrue(entries[0]["stream"])
        self.assertEqual(entries[0]["status"], 500)

        stat = _wait_for_stat("al")
        self.assertIsNotNone(stat)
        self.assertEqual(stat["requests"], 1)
        self.assertEqual(stat["errors"], 1)

    def test_stream_client_disconnect_does_not_kill_gateway(self):
        """Client hang-up mid-stream is normal; gateway keeps serving after."""
        ALPHA.mode = "slow_stream"
        body = json.dumps(
            {"model": "al", "stream": True, "messages": []}
        ).encode()
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
        try:
            conn.request(
                "POST",
                "/v1/chat/completions",
                body=body,
                headers={"Content-Type": "application/json", "Content-Length": str(len(body))},
            )
            resp = conn.getresponse()
            self.assertEqual(resp.status, 200)
            # Read a little, then drop the client socket (BrokenPipe on server).
            resp.read(8)
            resp.close()
        finally:
            conn.close()

        # The slow upstream takes ~2 seconds to finish normally. Recording
        # promptly proves the gateway observed the downstream disconnect.
        entries = _wait_for_requests(1, timeout=1.0)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["status"], 200)
        self.assertTrue(entries[0]["stream"])

        # Gateway must still answer subsequent requests.
        ALPHA.mode = "ok"
        status, _, raw = _request(
            "POST", "/v1/chat/completions",
            {"model": "al", "messages": []},
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)["served_by"], "alpha")

    def test_midstream_upstream_failure_counted_as_error(self):
        ALPHA.mode = "truncate_stream"
        status, _, _ = _request(
            "POST", "/v1/chat/completions",
            {"model": "al", "stream": True, "messages": []},
        )
        # Upstream 200 headers were already forwarded before its body failed.
        self.assertEqual(status, 200)

        entries = _wait_for_requests(1)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["status"], 502)

        stat = _wait_for_stat("al")
        self.assertIsNotNone(stat)
        self.assertEqual(stat["requests"], 1)
        self.assertEqual(stat["errors"], 1)


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
                raw = resp.read()
        except urllib.error.HTTPError as e:
            try:
                status = e.code
                raw = e.read()
            finally:
                e.close()
        self.assertEqual(status, 400)
        self.assertIn("error", json.loads(raw))

    def _assert_structured_400(self, status, raw, *, substring=None):
        self.assertEqual(status, 400)
        data = json.loads(raw)
        self.assertIsInstance(data, dict)
        self.assertIn("error", data)
        self.assertIsInstance(data["error"], dict)
        self.assertIn("message", data["error"])
        if substring:
            self.assertIn(substring, data["error"]["message"].lower())

    def test_json_array_body_400_chat(self):
        """Valid JSON of the wrong top-level shape must not drop the connection."""
        status, _, raw = _request(
            "POST", "/v1/chat/completions", [{"role": "user", "content": "hi"}]
        )
        self._assert_structured_400(status, raw, substring="object")
        self.assertEqual(len(ALPHA.received), 0)

    def test_json_string_body_400_embeddings(self):
        status, _, raw = _request("POST", "/v1/embeddings", "not-an-object")
        self._assert_structured_400(status, raw, substring="object")
        self.assertEqual(len(ALPHA.received), 0)

    def test_json_number_body_400_completions(self):
        status, _, raw = _request("POST", "/v1/completions", 42)
        self._assert_structured_400(status, raw, substring="object")
        self.assertEqual(len(ALPHA.received), 0)

    def test_non_string_model_400(self):
        for bad_model in (123, True, ["al"], {"id": "al"}):
            with self.subTest(model=bad_model):
                status, _, raw = _request(
                    "POST",
                    "/v1/chat/completions",
                    {"model": bad_model, "messages": []},
                )
                self._assert_structured_400(status, raw, substring="model")
                self.assertEqual(len(ALPHA.received), 0)

    def test_null_model_falls_back_to_default(self):
        # null/omitted model is allowed — gateway fills default_model.
        status, _, raw = _request(
            "POST", "/v1/chat/completions", {"model": None, "messages": []}
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)["served_by"], "alpha")

    def test_control_wrong_shape_400(self):
        for body in (["nope"], "nope", 7):
            with self.subTest(body=body):
                status, headers, raw = _request("POST", "/control/ping", body)
                self._assert_structured_400(status, raw, substring="object")
                # Control error responses never carry CORS.
                self.assertNotIn("Access-Control-Allow-Origin", headers)

    def test_control_invalid_json_400(self):
        req = urllib.request.Request(
            BASE + "/control/ping", data=b"{not json", method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                status = resp.status
                raw = resp.read()
                headers = dict(resp.headers.items())
        except urllib.error.HTTPError as e:
            try:
                status = e.code
                raw = e.read()
                headers = dict(e.headers.items())
            finally:
                e.close()
        self.assertEqual(status, 400)
        self.assertIn("error", json.loads(raw))
        self.assertNotIn("Access-Control-Allow-Origin", headers)

    def test_invalid_utf8_400(self):
        for path in ("/v1/chat/completions", "/control/ping"):
            with self.subTest(path=path):
                req = urllib.request.Request(BASE + path, data=b"\xff\xfe", method="POST")
                try:
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        status = resp.status
                        headers = dict(resp.headers.items())
                        raw = resp.read()
                except urllib.error.HTTPError as e:
                    try:
                        status = e.code
                        headers = dict(e.headers.items())
                        raw = e.read()
                    finally:
                        e.close()
                self._assert_structured_400(status, raw, substring="invalid json")
                if path.startswith("/control/"):
                    self.assertNotIn("Access-Control-Allow-Origin", headers)

    def test_oversized_json_integer_400(self):
        # Python rejects integers beyond its conversion limit with ValueError;
        # that parser failure must still become a structured client response.
        raw_body = b'{"model":' + (b"9" * 10000) + b',"messages":[]}'
        req = urllib.request.Request(
            BASE + "/v1/chat/completions", data=raw_body, method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                status = resp.status
                raw = resp.read()
        except urllib.error.HTTPError as e:
            try:
                status = e.code
                raw = e.read()
            finally:
                e.close()
        self._assert_structured_400(status, raw, substring="invalid json")

    def test_control_body_read_errors_carry_no_cors(self):
        cases = (
            ("not-a-number", 400),
            ("-1", 400),
            (str(64 * 1024 * 1024), 413),
        )
        for content_length, expected in cases:
            with self.subTest(content_length=content_length):
                conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
                try:
                    conn.putrequest("POST", "/control/ping")
                    conn.putheader("Content-Length", content_length)
                    conn.endheaders()
                    resp = conn.getresponse()
                    headers = dict(resp.headers.items())
                    self.assertEqual(resp.status, expected)
                    self.assertNotIn("Access-Control-Allow-Origin", headers)
                    self.assertIn("error", json.loads(resp.read()))
                finally:
                    conn.close()

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
