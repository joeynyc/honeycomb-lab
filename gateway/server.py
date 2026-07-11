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

import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
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


def resolve_model(model: str | None) -> tuple[str, str, str | None]:
    """Return (backend_id, upstream_model_or_empty, alias_used)."""
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

    # Stable aliases first
    for alias, spec in ALIASES.items():
        if alias == "default":
            continue
        bid = spec["backend"]
        be = BACKENDS.get(bid, {})
        ok, upstream, _ = backend_healthy(be.get("base_url", ""))
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
        ok, models, _ = backend_healthy(be.get("base_url", ""))
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
        log(f"{self.address_string()} {fmt % args}")

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
            for bid, be in BACKENDS.items():
                ok, models, ms = backend_healthy(be["base_url"])
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
            }
            self._send(200, json.dumps(payload, indent=2).encode())
            return

        if path == "/v1/models":
            data = {"object": "list", "data": merge_models()}
            self._send(200, json.dumps(data).encode())
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
            ok, models, _ = backend_healthy(base)
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
            if models:
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
        try:
            if stream:
                self._proxy_stream(target, body)
            else:
                status, _, resp = http_json("POST", target, body=body, timeout=300.0)
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
        try:
            with urllib.request.urlopen(req, timeout=300.0) as resp:
                self.send_response(resp.status)
                ctype = resp.headers.get("Content-Type", "text/event-stream")
                self.send_header("Content-Type", ctype)
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()
                while True:
                    chunk = resp.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except urllib.error.HTTPError as e:
            err = e.read()
            self._send(e.code, err or json.dumps({"error": str(e)}).encode())
        except Exception as e:
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
