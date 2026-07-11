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


def load_config() -> dict[str, Any]:
    with CONFIG_PATH.open() as f:
        return json.load(f)


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
    if model in ("cheap", "auto-cheap"):
        if resolved := resolve_cheap():
            return resolved
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


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        line = fmt % args
        # Health polls arrive every few seconds; logging them bloats the
        # launchd log by ~19k lines/day with zero signal.
        if '"GET /health' in line and line.rstrip(" -").endswith("200"):
            return
        log(f"{self.address_string()} {line}")

    def _send(self, code: int, body: bytes, content_type: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> bytes:
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"

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

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"
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
            # Prefer a chat-capable model: embedding models can't serve
            # /chat/completions but may sort first in the backend's list.
            chat_models = [m for m in models if "embed" not in m.lower()]
            if chat_models:
                upstream = chat_models[0]
            elif models:
                upstream = models[0]
            else:
                upstream = model if model not in ALIASES else "default"

        payload["model"] = upstream
        stream = bool(payload.get("stream"))
        body = json.dumps(payload).encode()
        # path is /v1/... — append to base that already ends with /v1
        suffix = path[len("/v1") :]  # /chat/completions
        target = base + suffix

        log(
            f"route model={model!r} alias={alias!r} → {bid} upstream={upstream!r} stream={stream}"
        )

        activity_begin(bid, upstream, alias or model)
        t0 = time.perf_counter()
        try:
            if stream:
                self._proxy_stream(target, body)
                record_request(
                    alias or model, bid, upstream, True,
                    None, (time.perf_counter() - t0) * 1000, None, None,
                )
            else:
                status, _, resp = http_json("POST", target, body=body, timeout=300.0)
                duration_ms = (time.perf_counter() - t0) * 1000
                prompt_tokens = completion_tokens = None
                try:
                    usage = json.loads(resp.decode()).get("usage") or {}
                    prompt_tokens = usage.get("prompt_tokens")
                    completion_tokens = usage.get("completion_tokens")
                except Exception:
                    pass
                record_request(
                    alias or model, bid, upstream, False,
                    status if status else 502, duration_ms,
                    prompt_tokens, completion_tokens,
                )
                if status == 0:
                    self._send(502, resp)
                else:
                    self._send(status if status else 502, resp)
        finally:
            activity_end(bid)

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
