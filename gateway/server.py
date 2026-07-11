#!/usr/bin/env python3
"""Honeycomb Lab gateway — single OpenAI-compatible front door on the Mac mini.

  GET  /health
  GET  /v1/models
  POST /v1/chat/completions   (stream + non-stream)
  POST /v1/completions
  POST /v1/embeddings

Routes by model alias (config.json) or passthrough model@backend / backend/model.
"""

from __future__ import annotations

import collections
import hmac
import ipaddress
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = Path(os.environ.get("HONEYCOMB_GATEWAY_CONFIG", ROOT / "config.json"))
DASHBOARD_PATH = ROOT / "dashboard.html"

sys.path.insert(0, str(ROOT))
import nodes as fleet_nodes  # noqa: E402


def load_config() -> dict[str, Any]:
    """Fresh clones won't have config.json yet (it's gitignored) — fall back
    to the example with a loud warning instead of crash-looping under
    launchd/systemd."""
    try:
        with CONFIG_PATH.open() as f:
            return json.load(f)
    except FileNotFoundError:
        example = CONFIG_PATH.parent / "config.example.json"
        print(
            f"[gateway] {CONFIG_PATH} not found — copy {example.name} to "
            f"config.json and edit your backends. Starting with the example "
            f"config so you can see the dashboard.",
            flush=True,
        )
        with example.open() as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        raise SystemExit(f"[gateway] {CONFIG_PATH} is not valid JSON: {e}") from e


CFG = load_config()
BACKENDS: dict[str, dict[str, Any]] = CFG["backends"]
ALIASES: dict[str, dict[str, Any]] = CFG.get("aliases", {})
DEFAULT_MODEL = CFG.get("default_model", "spark-peer")
# Cheapest-first backend order for the dynamic "cheap" alias — small local
# model on the Mini before waking a Spark-class GPU.
CHEAP_ORDER: list[str] = [
    b for b in CFG.get("cheap_order", ["lms", "gx10", "joeydgx"]) if b in BACKENDS
]

# Live traffic for Honeycomb "lit" hexes (thread-safe)
_activity_lock = threading.Lock()
# backend_id -> {last_request_at, in_flight, request_count, last_model, last_alias}
_activity: dict[str, dict[str, Any]] = {
    bid: {
        "last_request_at": None,
        "in_flight": 0,
        "request_count": 0,
        "last_model": None,
        "last_alias": None,
    }
    for bid in BACKENDS
}
# How long after last byte a node stays "lit" (seconds)
ACTIVE_WINDOW_SEC = 8.0

# Recent request history for the /requests endpoint (thread-safe ring buffer)
_requests_lock = threading.Lock()
_request_log: collections.deque[dict[str, Any]] = collections.deque(maxlen=50)

# Per-alias cumulative stats, persisted to stats.json (thread-safe)
STATS_PATH = ROOT / "stats.json"
STATS_WRITE_INTERVAL_SEC = 30.0
_stats_lock = threading.Lock()
_stats: dict[str, dict[str, Any]] = {}
_stats_last_write = 0.0


def _load_stats() -> None:
    global _stats
    try:
        with STATS_PATH.open() as f:
            data = json.load(f)
        if isinstance(data, dict):
            _stats = data
    except FileNotFoundError:
        pass
    except Exception as e:
        log(f"stats load failed: {e}")


def _save_stats_if_due() -> None:
    global _stats_last_write
    now = time.time()
    with _stats_lock:
        if now - _stats_last_write < STATS_WRITE_INTERVAL_SEC:
            return
        _stats_last_write = now
        snapshot = json.dumps(_stats, indent=2)
    tmp = STATS_PATH.with_suffix(".json.tmp")
    try:
        tmp.write_text(snapshot)
        os.replace(tmp, STATS_PATH)
    except Exception as e:
        log(f"stats save failed: {e}")


def stats_snapshot() -> dict[str, Any]:
    with _stats_lock:
        return {k: dict(v) for k, v in _stats.items()}


MAX_STATS_KEYS = 200


def _update_stats(
    key: str,
    status: int | None,
    duration_ms: float | None,
    prompt_tokens: int | None,
    completion_tokens: int | None,
) -> None:
    is_error = status is None or status == 0 or status >= 400
    with _stats_lock:
        # Keys come from client-supplied model names — cap so a chatty or
        # malicious client can't grow memory/disk without bound.
        if key not in _stats and len(_stats) >= MAX_STATS_KEYS:
            key = "(other)"
        s = _stats.setdefault(
            key,
            {
                "requests": 0,
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_duration_ms": 0.0,
                "errors": 0,
            },
        )
        s["requests"] += 1
        if prompt_tokens:
            s["prompt_tokens"] += prompt_tokens
        if completion_tokens:
            s["completion_tokens"] += completion_tokens
        if duration_ms:
            s["total_duration_ms"] += duration_ms
        if is_error:
            s["errors"] += 1
    _save_stats_if_due()


def record_request(
    alias: str | None,
    backend: str,
    model: str,
    stream: bool,
    status: int | None,
    duration_ms: float | None,
    prompt_tokens: int | None,
    completion_tokens: int | None,
) -> None:
    entry = {
        "ts": time.time(),
        "alias": alias,
        "backend": backend,
        "model": model,
        "stream": stream,
        "status": status,
        "duration_ms": duration_ms,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
    }
    with _requests_lock:
        _request_log.append(entry)
    _update_stats(alias or model, status, duration_ms, prompt_tokens, completion_tokens)


def log(msg: str) -> None:
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def activity_begin(backend_id: str, model: str | None, alias: str | None) -> None:
    with _activity_lock:
        slot = _activity.setdefault(
            backend_id,
            {
                "last_request_at": None,
                "in_flight": 0,
                "request_count": 0,
                "last_model": None,
                "last_alias": None,
            },
        )
        slot["in_flight"] = int(slot.get("in_flight") or 0) + 1
        slot["request_count"] = int(slot.get("request_count") or 0) + 1
        slot["last_request_at"] = time.time()
        slot["last_model"] = model
        slot["last_alias"] = alias


def activity_end(backend_id: str) -> None:
    with _activity_lock:
        slot = _activity.get(backend_id)
        if not slot:
            return
        slot["in_flight"] = max(0, int(slot.get("in_flight") or 0) - 1)
        slot["last_request_at"] = time.time()


def activity_snapshot() -> dict[str, Any]:
    now = time.time()
    with _activity_lock:
        out: dict[str, Any] = {}
        for bid, slot in _activity.items():
            last = slot.get("last_request_at")
            in_flight = int(slot.get("in_flight") or 0)
            age = (now - last) if last else None
            active = in_flight > 0 or (age is not None and age < ACTIVE_WINDOW_SEC)
            out[bid] = {
                "active": active,
                "in_flight": in_flight,
                "request_count": int(slot.get("request_count") or 0),
                "last_request_at": last,
                "seconds_since_request": round(age, 2) if age is not None else None,
                "last_model": slot.get("last_model"),
                "last_alias": slot.get("last_alias"),
            }
        return out


def http_json(
    method: str,
    url: str,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = 8.0,
) -> tuple[int, dict[str, str], bytes]:
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Accept", "application/json")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        if k.lower() not in ("host", "content-length"):
            req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, dict(resp.headers.items()), raw
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers.items()) if e.headers else {}, e.read()
    except Exception as e:
        return 0, {}, json.dumps({"error": {"message": str(e), "type": "gateway_error"}}).encode()


def backend_healthy(base_url: str) -> tuple[bool, list[str], float | None]:
    url = base_url.rstrip("/") + "/models"
    t0 = time.perf_counter()
    status, _, raw = http_json("GET", url, timeout=3.0)
    ms = (time.perf_counter() - t0) * 1000
    if status != 200:
        return False, [], None
    try:
        data = json.loads(raw.decode() or "{}")
        models = [m.get("id") for m in data.get("data", []) if m.get("id")]
        return True, models, ms
    except Exception:
        return True, [], ms


# Probe cache: /health and /v1/models must never stack serial 3s timeouts
# when a backend host is unreachable — probe concurrently and reuse results
# for a couple of seconds.
_probe_lock = threading.Lock()
_probe_cache: dict[str, tuple[float, tuple[bool, list[str], float | None]]] = {}
_probe_pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="probe")
PROBE_TTL_SEC = 2.5


_probe_refreshing: set[str] = set()


def _probe_refresh(bid: str) -> None:
    be = BACKENDS.get(bid)
    result = backend_healthy(be["base_url"]) if be else (False, [], None)
    with _probe_lock:
        _probe_cache[bid] = (time.time(), result)
        _probe_refreshing.discard(bid)


def backend_status(bid: str) -> tuple[bool, list[str], float | None]:
    """backend_healthy with a stale-while-revalidate cache, keyed by backend id.

    Fresh hit → cached result. Stale hit → cached result now, refresh in the
    background. Only a cold miss (first probe ever) blocks — so /health stays
    fast even while an unreachable host makes probes eat their full timeout.
    """
    now = time.time()
    with _probe_lock:
        hit = _probe_cache.get(bid)
        if hit:
            if now - hit[0] >= PROBE_TTL_SEC and bid not in _probe_refreshing:
                _probe_refreshing.add(bid)
                _probe_pool.submit(_probe_refresh, bid)
            return hit[1]
    be = BACKENDS.get(bid)
    result = backend_healthy(be["base_url"]) if be else (False, [], None)
    with _probe_lock:
        _probe_cache[bid] = (time.time(), result)
    return result


def all_backend_status() -> dict[str, tuple[bool, list[str], float | None]]:
    """Probe every backend concurrently; worst case = one probe timeout."""
    futures = {bid: _probe_pool.submit(backend_status, bid) for bid in BACKENDS}
    return {bid: f.result() for bid, f in futures.items()}


def resolve_cheap() -> tuple[str, str, str | None] | None:
    """First backend in CHEAP_ORDER that is healthy with a chat model loaded."""
    for bid in CHEAP_ORDER:
        ok, models, _ = backend_status(bid)
        chat = [m for m in models if "embed" not in m.lower()]
        if ok and chat:
            return bid, chat[0], "cheap"
    return None


def resolve_model(model: str | None) -> tuple[str, str, str | None]:
    """Return (backend_id, upstream_model_or_empty, alias_used)."""
    # Cost-aware routing: prefer the cheapest available model, fall back to
    # the normal default when nothing cheap is up.
    if model in ("cheap", "auto-cheap", "any"):
        if resolved := resolve_cheap():
            bid, up, _ = resolved
            return bid, up, "any" if model == "any" else "cheap"
        model = DEFAULT_MODEL

    if not model or model in ("default", "auto"):
        model = DEFAULT_MODEL

    # alias
    if model in ALIASES:
        a = ALIASES[model]
        bid = a["backend"]
        up = a.get("upstream_model")
        return bid, up or "", model

    # model@backend
    if "@" in model:
        name, bid = model.rsplit("@", 1)
        if bid in BACKENDS:
            return bid, name, None

    # backend/model
    if "/" in model:
        bid, _, rest = model.partition("/")
        if bid in BACKENDS:
            return bid, rest, None

    # bare backend id → first model or empty (upstream decides)
    if model in BACKENDS:
        return model, "", None

    # default: try gx10 then lms with original name
    if "gx10" in BACKENDS:
        return "gx10", model, None
    return next(iter(BACKENDS)), model, None


def merge_models() -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    statuses = all_backend_status()

    # Dynamic cost-aware alias
    cheap = resolve_cheap()
    out.append(
        {
            "id": "cheap",
            "object": "model",
            "owned_by": "honeycomb/dynamic",
            "backend": cheap[0] if cheap else None,
            "resolves_to": cheap[1] if cheap else None,
            "healthy": cheap is not None,
            "order": CHEAP_ORDER,
        }
    )
    seen.add("cheap")

    # Dynamic failover alias — same resolution as "cheap", but do_POST
    # retries remaining CHEAP_ORDER backends on upstream failure.
    any_resolved = resolve_cheap()
    out.append(
        {
            "id": "any",
            "object": "model",
            "owned_by": "honeycomb/dynamic",
            "backend": any_resolved[0] if any_resolved else None,
            "resolves_to": any_resolved[1] if any_resolved else None,
            "healthy": any_resolved is not None,
            "order": CHEAP_ORDER,
        }
    )
    seen.add("any")

    # Stable aliases first
    for alias, spec in ALIASES.items():
        if alias == "default":
            continue
        bid = spec["backend"]
        be = BACKENDS.get(bid, {})
        ok, upstream, _ = statuses.get(bid, (False, [], None))
        entry = {
            "id": alias,
            "object": "model",
            "owned_by": f"honeycomb/{bid}",
            "backend": bid,
            "backend_name": be.get("name", bid),
            "healthy": ok,
            "upstream_models": upstream,
        }
        out.append(entry)
        seen.add(alias)

    # Live upstream models as backend/model ids
    for bid, be in BACKENDS.items():
        ok, models, _ = statuses.get(bid, (False, [], None))
        if not ok:
            continue
        for mid in models:
            full = f"{bid}/{mid}"
            if full in seen:
                continue
            out.append(
                {
                    "id": full,
                    "object": "model",
                    "owned_by": f"honeycomb/{bid}",
                    "backend": bid,
                    "root": mid,
                }
            )
            seen.add(full)

    return out


def _proxy_attempt(
    bid: str,
    upstream: str,
    alias: str | None,
    suffix: str,
    payload: dict[str, Any],
    requested_model: str,
) -> tuple[int, bytes]:
    """One non-stream proxy attempt to a specific backend. Records activity + stats."""
    be = BACKENDS[bid]
    base = be["base_url"].rstrip("/")
    body_payload = dict(payload)
    body_payload["model"] = upstream
    body = json.dumps(body_payload).encode()
    target = base + suffix

    log(
        f"route model={requested_model!r} alias={alias!r} → {bid} upstream={upstream!r} stream=False"
    )
    activity_begin(bid, upstream, alias or requested_model)
    t0 = time.perf_counter()
    try:
        status, _, resp = http_json("POST", target, body=body, timeout=300.0)
    finally:
        activity_end(bid)
    duration_ms = (time.perf_counter() - t0) * 1000
    prompt_tokens = completion_tokens = None
    try:
        usage = json.loads(resp.decode()).get("usage") or {}
        prompt_tokens = usage.get("prompt_tokens")
        completion_tokens = usage.get("completion_tokens")
    except Exception:
        pass
    record_request(
        alias or requested_model, bid, upstream, False,
        status if status else 502, duration_ms,
        prompt_tokens, completion_tokens,
    )
    return status, resp


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        line = fmt % args
        # Health polls arrive every few seconds; logging them bloats the
        # launchd log by ~19k lines/day with zero signal.
        if '"GET /health' in line and line.rstrip(" -").endswith("200"):
            return
        log(f"{self.address_string()} {line}")

    def _send(
        self,
        code: int,
        body: bytes,
        content_type: str = "application/json",
        cors: bool = True,
    ) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        # Control responses never get CORS — a malicious page in a browser on
        # this network must not be able to read them or script the actions.
        if cors:
            self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    MAX_BODY_BYTES = 32 * 1024 * 1024  # plenty for chat payloads

    def _read_body(self) -> bytes:
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._send(400, json.dumps({"error": {"message": "bad Content-Length"}}).encode())
            raise ConnectionAbortedError("bad content-length") from None
        if n < 0:
            n = 0
        if n > self.MAX_BODY_BYTES:
            # Refuse to buffer absurd payloads into memory.
            self._send(413, json.dumps({"error": {"message": "request too large"}}).encode())
            raise ConnectionAbortedError("body too large")
        return self.rfile.read(n) if n else b""

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"

        # Browsers get the dashboard at /; API clients keep getting JSON.
        wants_html = "text/html" in (self.headers.get("Accept") or "")
        if (path == "/" and wants_html) or path == "/dashboard":
            try:
                body = DASHBOARD_PATH.read_bytes()
                self._send(200, body, content_type="text/html; charset=utf-8")
            except OSError:
                self._send(404, json.dumps({"error": {"message": "dashboard.html missing"}}).encode())
            return

        if path == "/nodes":
            payload = fleet_nodes.snapshot(activity_snapshot())
            # Doctor findings describe the machine's config/health posture —
            # only hand them to callers who could have run the scan anyway.
            if not self._control_authorized():
                for n in payload.get("nodes", []):
                    n["doctor"] = None
            self._send(200, json.dumps(payload).encode())
            return

        if path in ("/", "/health"):
            backends = {}
            act = activity_snapshot()
            statuses = all_backend_status()
            for bid, be in BACKENDS.items():
                ok, models, ms = statuses[bid]
                a = act.get(bid, {})
                backends[bid] = {
                    "name": be.get("name"),
                    "base_url": be["base_url"],
                    "healthy": ok,
                    "latency_ms": round(ms, 1) if ms is not None else None,
                    "models": models,
                    "active": a.get("active", False),
                    "in_flight": a.get("in_flight", 0),
                    "request_count": a.get("request_count", 0),
                    "last_request_at": a.get("last_request_at"),
                    "seconds_since_request": a.get("seconds_since_request"),
                    "last_model": a.get("last_model"),
                    "last_alias": a.get("last_alias"),
                }
            # Map gateway backends → Honeycomb hex ids for the Mac app
            node_activity = {
                "gx10": act.get("gx10", {}).get("active", False),
                "joeydgx": act.get("joeydgx", {}).get("active", False),
                "mini": act.get("lms", {}).get("active", False),
                "pc4080": bool(
                    act.get("lms", {}).get("active")
                    and str(act.get("lms", {}).get("last_alias") or "").startswith("pc")
                ),
            }
            payload = {
                "status": "ok",
                "service": "honeycomb-gateway",
                "default_model": DEFAULT_MODEL,
                "backends": backends,
                "activity": act,
                "node_activity": node_activity,
                "active_window_sec": ACTIVE_WINDOW_SEC,
                "aliases": {
                    k: v for k, v in ALIASES.items() if k != "default"
                },
                "cheap": {
                    "order": CHEAP_ORDER,
                    "resolves_to": (
                        {"backend": c[0], "model": c[1]}
                        if (c := resolve_cheap())
                        else None
                    ),
                },
                "stats": stats_snapshot(),
            }
            self._send(200, json.dumps(payload, indent=2).encode())
            return

        if path == "/v1/models":
            data = {"object": "list", "data": merge_models()}
            self._send(200, json.dumps(data).encode())
            return

        if path == "/requests":
            with _requests_lock:
                entries = list(reversed(_request_log))
            self._send(200, json.dumps({"requests": entries}).encode())
            return

        self._send(404, json.dumps({"error": {"message": f"not found: {path}"}}).encode())

    def _host_is_literal(self) -> bool:
        """True when the Host header is an IP literal or localhost.

        Browsers doing DNS rebinding must send the attacker's *domain* in
        Host, even after the name resolves to 127.0.0.1 — so requiring a
        literal address defeats rebinding without breaking real clients
        (the app, curl, and the dashboard all address the hub by IP or
        localhost).
        """
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]").lower()
        if host in ("localhost", "127.0.0.1", "::1", ""):
            return True
        try:
            ipaddress.ip_address(host)
            return True
        except ValueError:
            # A MagicDNS/tailnet name is a legitimate way to reach the hub;
            # allow explicitly configured hostnames only.
            return host in {h.lower() for h in CFG.get("allowed_hosts", [])}

    def _token_valid(self) -> bool:
        token = CFG.get("control_token") or ""
        supplied = self.headers.get("X-Honeycomb-Token") or ""
        # Placeholder values from the example config never authorize.
        if not token or " " in token or token.startswith("__"):
            return False
        return hmac.compare_digest(supplied, token)

    def _control_authorized(self) -> bool:
        """Control actions run remote commands. Localhost is exempt from the
        token (the Mac app, local curl) — but only when the request also
        carries a literal Host, so a rebound browser request can't inherit
        the exemption."""
        if not self._host_is_literal():
            return False
        if self.client_address[0] in ("127.0.0.1", "::1"):
            return True
        return self._token_valid()

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"

        if path.startswith("/control/"):
            if not self._control_authorized():
                self._send(401, json.dumps({"error": {"message": "control token required"}}).encode(), cors=False)
                return
            raw = self._read_body()
            try:
                body = json.loads(raw.decode() or "{}")
            except json.JSONDecodeError:
                self._send(400, json.dumps({"error": {"message": "invalid json"}}).encode(), cors=False)
                return
            node_id = str(body.get("node") or "")
            action = path.removeprefix("/control/")
            if action == "ping":
                result = fleet_nodes.action_ping(node_id, int(CFG.get("listen_port", 4000)))
            elif action == "doctor":
                result = fleet_nodes.action_doctor(node_id)
            elif action == "container":
                result = fleet_nodes.action_container(node_id, str(body.get("verb") or ""))
            else:
                self._send(404, json.dumps({"error": {"message": f"unknown action {action}"}}).encode(), cors=False)
                return
            log(f"control {action} node={node_id!r} ok={result.get('ok')}")
            self._send(200, json.dumps(result).encode(), cors=False)
            return

        if path not in (
            "/v1/chat/completions",
            "/v1/completions",
            "/v1/embeddings",
        ):
            self._send(404, json.dumps({"error": {"message": f"not found: {path}"}}).encode())
            return

        raw = self._read_body()
        try:
            payload = json.loads(raw.decode() or "{}")
        except json.JSONDecodeError:
            self._send(400, json.dumps({"error": {"message": "invalid json"}}).encode())
            return

        # "failover": true opts a non-stream request into backend retry on
        # upstream failure; pop it so it never reaches the upstream API.
        failover_requested = bool(payload.pop("failover", False))

        model = payload.get("model") or DEFAULT_MODEL
        bid, upstream, alias = resolve_model(model)
        if bid not in BACKENDS:
            self._send(
                400,
                json.dumps({"error": {"message": f"unknown backend for model {model!r}"}}).encode(),
            )
            return

        be = BACKENDS[bid]
        base = be["base_url"].rstrip("/")

        # If alias has no fixed upstream, pick first healthy model on backend
        if not upstream:
            ok, models, _ = backend_status(bid)
            if not ok:
                # With failover enabled, fall through so the retry loop can
                # pick a healthy backend instead of failing here.
                if not (failover_requested or model == "any") or bool(payload.get("stream")):
                    self._send(
                        502,
                        json.dumps(
                            {
                                "error": {
                                    "message": f"backend {bid} unhealthy ({be.get('name')})",
                                    "type": "backend_down",
                                    "backend": bid,
                                }
                            }
                        ).encode(),
                    )
                    return
                models = []
            # Prefer a chat-capable model: embedding models can't serve
            # /chat/completions but may sort first in the backend's list.
            chat_models = [m for m in models if "embed" not in m.lower()]
            if chat_models:
                upstream = chat_models[0]
            elif models:
                upstream = models[0]
            else:
                upstream = model if model not in ALIASES else "default"

        stream = bool(payload.get("stream"))
        # path is /v1/... — append to base that already ends with /v1
        suffix = path[len("/v1") :]  # /chat/completions

        if stream:
            payload["model"] = upstream
            body = json.dumps(payload).encode()
            target = base + suffix
            log(
                f"route model={model!r} alias={alias!r} → {bid} upstream={upstream!r} stream=True"
            )
            activity_begin(bid, upstream, alias or model)
            t0 = time.perf_counter()
            try:
                self._proxy_stream(target, body)
                record_request(
                    alias or model, bid, upstream, True,
                    None, (time.perf_counter() - t0) * 1000, None, None,
                )
            finally:
                activity_end(bid)
            return

        # Non-stream: proxy, and on upstream failure with failover enabled
        # (explicit "failover": true, or the "any" alias) retry once per
        # remaining CHEAP_ORDER backend before giving up.
        do_failover = failover_requested or model == "any"
        status, resp = _proxy_attempt(bid, upstream, alias, suffix, payload, model)

        if do_failover and (status == 0 or status >= 500):
            tried = {bid}
            for cand_bid in CHEAP_ORDER:
                if cand_bid in tried:
                    continue
                tried.add(cand_bid)
                ok, cand_models, _ = backend_status(cand_bid)
                chat_models = [m for m in cand_models if "embed" not in m.lower()] if ok else []
                if not chat_models:
                    continue
                log(f"failover: {bid} failed (status={status}) → trying {cand_bid}")
                bid = cand_bid
                upstream = chat_models[0]
                status, resp = _proxy_attempt(bid, upstream, alias, suffix, payload, model)
                if not (status == 0 or status >= 500):
                    break

        if status == 0:
            self._send(502, resp)
        else:
            self._send(status if status else 502, resp)

    def _proxy_stream(self, url: str, body: bytes) -> None:
        req = urllib.request.Request(url, data=body, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "text/event-stream")
        headers_sent = False
        try:
            with urllib.request.urlopen(req, timeout=300.0) as resp:
                self.send_response(resp.status)
                ctype = resp.headers.get("Content-Type", "text/event-stream")
                self.send_header("Content-Type", ctype)
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()
                headers_sent = True
                while True:
                    chunk = resp.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # Client hung up mid-stream (closed the chat) — normal, not an error.
            log("stream client disconnected")
        except urllib.error.HTTPError as e:
            err = e.read()
            if not headers_sent:
                self._send(e.code, err or json.dumps({"error": str(e)}).encode())
        except Exception as e:
            # Once the 200 + headers are on the wire we can't send a second
            # response — just log and drop the connection.
            if headers_sent:
                log(f"stream error after headers: {e}")
            else:
                self._send(
                    502,
                    json.dumps({"error": {"message": str(e), "type": "stream_error"}}).encode(),
                )


def main() -> None:
    host = CFG.get("listen_host", "0.0.0.0")
    port = int(CFG.get("listen_port", 4000))
    _load_stats()
    fleet_nodes.start_prober()
    log(f"Honeycomb gateway → http://{host}:{port}")
    log(f"config: {CONFIG_PATH}")
    for bid, be in BACKENDS.items():
        ok, models, ms = backend_healthy(be["base_url"])
        st = "UP" if ok else "DOWN"
        log(f"  backend {bid:8} {st:4}  {be['base_url']}  models={models[:3]}  {f'{ms:.0f}ms' if ms else ''}")
    log(f"default model alias: {DEFAULT_MODEL}")
    log("aliases: " + ", ".join(a for a in ALIASES if a != "default"))

    httpd = ThreadingHTTPServer((host, port), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("shutdown")
        httpd.server_close()


if __name__ == "__main__":
    main()
