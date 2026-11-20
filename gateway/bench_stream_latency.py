#!/usr/bin/env python3
"""Measure time to first complete SSE event through a gateway.

The upstream and gateway are always bound to 127.0.0.1. Use --gateway-dir
to run this harness against an isolated checkout of another revision, for
example a directory produced by `git archive`.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


EVENTS = [
    b'data: {"choices":[{"delta":{"content":"one"}}]}\n\n',
    b'data: {"choices":[{"delta":{"content":"two"}}]}\n\n',
    b'data: {"choices":[{"delta":{"content":"three"}}]}\n\n',
    b'data: {"choices":[{"delta":{"content":"four"}}]}\n\n',
    b'data: {"choices":[{"delta":{"content":"five"}}]}\n\n',
    b"data: [DONE]\n\n",
]


class FakeBackend(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path == "/v1/models":
            body = json.dumps({"data": [{"id": "fixture-chat"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        size = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(size)
        if self.headers.get("Accept") == "text/event-stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            if self.server.framing == "content-length":
                self.send_header(
                    "Content-Length", str(sum(len(event) for event in EVENTS))
                )
            else:
                self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for index, event in enumerate(EVENTS):
                if self.server.framing == "chunked":
                    self.wfile.write(
                        f"{len(event):X}\r\n".encode() + event + b"\r\n"
                    )
                else:
                    self.wfile.write(event)
                self.wfile.flush()
                if index + 1 < len(EVENTS):
                    time.sleep(self.server.interval)
            if self.server.framing == "chunked":
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            return
        body = b'{}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def read_event(response) -> bytes:
    event = bytearray()
    while b"\n\n" not in event:
        chunk = response.read1(4096)
        if not chunk:
            raise RuntimeError("upstream ended before a complete SSE event")
        event.extend(chunk)
    return bytes(event)


def measure_once(port: int, *, model: str) -> tuple[float, float]:
    body = json.dumps(
        {"model": model, "stream": True, "messages": [{"role": "user", "content": "x"}]}
    ).encode()
    conn = HTTPConnection("127.0.0.1", port, timeout=30)
    started = time.perf_counter()
    try:
        conn.request(
            "POST",
            "/v1/chat/completions",
            body=body,
            headers={
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
                "Content-Length": str(len(body)),
            },
        )
        response = conn.getresponse()
        if response.status != 200:
            raise RuntimeError(f"unexpected status {response.status}")
        received = read_event(response)
        first_ms = (time.perf_counter() - started) * 1000
        received += response.read()
        expected = b"".join(EVENTS)
        if received != expected:
            raise RuntimeError(
                f"corrupt or incomplete stream: got {len(received)} bytes, "
                f"expected {len(expected)}"
            )
        total_ms = (time.perf_counter() - started) * 1000
        return first_ms, total_ms
    finally:
        conn.close()


def percentile(values: list[float], rank: float) -> float:
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int(len(ordered) * rank + 0.999999) - 1))
    return ordered[index]


def summarize(values: list[float]) -> str:
    return "p50={:.3f}ms p95={:.3f}ms p99={:.3f}ms max={:.3f}ms".format(
        statistics.median(values),
        percentile(values, 0.95),
        percentile(values, 0.99),
        max(values),
    )


def run_series(port: int, count: int, concurrency: int, model: str):
    if concurrency == 1:
        return [measure_once(port, model=model) for _ in range(count)]
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        return list(pool.map(lambda _item: measure_once(port, model=model), range(count)))


def start_gateway(gateway_dir: Path, upstream_port: int, root: Path):
    config = {
        "listen_host": "127.0.0.1",
        "listen_port": 0,
        "default_model": "local",
        "backends": {
            "fixture": {
                "name": "Loopback fixture",
                "base_url": f"http://127.0.0.1:{upstream_port}/v1",
            }
        },
        "aliases": {"local": {"backend": "fixture", "upstream_model": "fixture-chat"}},
        "cheap_order": ["fixture"],
    }
    config_path = root / "gateway.json"
    fleet_path = root / "fleet.json"
    config_path.write_text(json.dumps(config))
    fleet_path.write_text(json.dumps({"title": "LOOPBACK", "nodes": [], "links": []}))
    os.environ["HONEYCOMB_GATEWAY_CONFIG"] = str(config_path)
    os.environ["HONEYCOMB_FLEET"] = str(fleet_path)
    sys.path.insert(0, str(gateway_dir))
    import server

    server.log = lambda *_args: None
    server.STATS_PATH = root / "stats.json"
    gateway = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
    threading.Thread(target=gateway.serve_forever, daemon=True).start()
    return gateway


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gateway-dir", type=Path, required=True)
    parser.add_argument("--framing", choices=("content-length", "chunked"), default="chunked")
    parser.add_argument("--samples", type=int, default=300)
    parser.add_argument("--warmups", type=int, default=30)
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--concurrency", type=int, default=1)
    parser.add_argument("--interval-ms", type=float, default=20.0)
    args = parser.parse_args()
    if args.samples <= 0:
        parser.error("--samples must be > 0")
    if args.repeats <= 0:
        parser.error("--repeats must be > 0")
    if args.concurrency <= 0:
        parser.error("--concurrency must be > 0")
    if args.warmups < 0:
        parser.error("--warmups must be >= 0")
    if args.interval_ms < 0:
        parser.error("--interval-ms must be >= 0")
    gateway_dir = args.gateway_dir.resolve()

    upstream = ThreadingHTTPServer(("127.0.0.1", 0), FakeBackend)
    upstream.framing = args.framing
    upstream.interval = args.interval_ms / 1000
    threading.Thread(target=upstream.serve_forever, daemon=True).start()

    with tempfile.TemporaryDirectory(prefix="honeycomb-stream-bench-") as temp:
        root = Path(temp)
        gateway = start_gateway(gateway_dir, upstream.server_address[1], root)
        try:
            print(
                f"framing={args.framing} samples={args.samples} warmups={args.warmups} "
                f"repeats={args.repeats} concurrency={args.concurrency} interval_ms={args.interval_ms:.1f}"
            )
            all_direct_first, all_direct_total = [], []
            all_gateway_first, all_gateway_total = [], []
            for repeat in range(1, args.repeats + 1):
                for _ in range(args.warmups):
                    measure_once(upstream.server_address[1], model="fixture-chat")
                    measure_once(gateway.server_address[1], model="local")
                direct = run_series(
                    upstream.server_address[1], args.samples, args.concurrency, "fixture-chat"
                )
                proxied = run_series(
                    gateway.server_address[1], args.samples, args.concurrency, "local"
                )
                direct_first = [value[0] for value in direct]
                direct_total = [value[1] for value in direct]
                gateway_first = [value[0] for value in proxied]
                gateway_total = [value[1] for value in proxied]
                all_direct_first.extend(direct_first)
                all_direct_total.extend(direct_total)
                all_gateway_first.extend(gateway_first)
                all_gateway_total.extend(gateway_total)
                print(
                    f"run={repeat} direct_first {summarize(direct_first)}; "
                    f"direct_total {summarize(direct_total)}"
                )
                print(
                    f"run={repeat} gateway_first {summarize(gateway_first)}; "
                    f"gateway_total {summarize(gateway_total)}"
                )
            print(
                f"aggregate direct_first {summarize(all_direct_first)}; "
                f"direct_total {summarize(all_direct_total)}"
            )
            print(
                f"aggregate gateway_first {summarize(all_gateway_first)}; "
                f"gateway_total {summarize(all_gateway_total)}"
            )
        finally:
            gateway.shutdown()
            gateway.server_close()
    upstream.shutdown()
    upstream.server_close()


if __name__ == "__main__":
    main()
