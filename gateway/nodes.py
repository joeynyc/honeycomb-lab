"""Node prober for the Honeycomb web dashboard.

Reads the same fleet.json the Mac app uses and keeps a cached status per
node (health, models, metrics, lit). Runs as a background thread inside the
gateway; GET /nodes serves the latest snapshot. Stdlib only.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

FLEET_PATH = Path(
    os.environ.get(
        "HONEYCOMB_FLEET",
        os.path.expanduser("~/Library/Application Support/Honeycomb/fleet.json"),
    )
)

PROBE_INTERVAL_SEC = 8.0
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "ConnectionAttempts=1"]

_lock = threading.Lock()
_fleet: dict[str, Any] = {"title": "HONEYCOMB", "nodes": [], "links": []}
_status: dict[str, dict[str, Any]] = {}
# node_id -> deque[(ts, health, latencyMs)] — rolling hour
_history: dict[str, Any] = {}
_last_change: dict[str, float] = {}
# node_id -> last doctor report {ts, findings, error}
_doctor: dict[str, dict[str, Any]] = {}
_pool = ThreadPoolExecutor(max_workers=6, thread_name_prefix="node-probe")
HISTORY_WINDOW_SEC = 3600


def _lms_path() -> str | None:
    for candidate in (
        os.path.expanduser("~/.lmstudio/bin/lms"),
        "/opt/homebrew/bin/lms",
        "/usr/local/bin/lms",
    ):
        if os.access(candidate, os.X_OK):
            return candidate
    return shutil.which("lms")


def _run(cmd: list[str], timeout: float) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
        return proc.returncode, proc.stdout
    except Exception:
        return -1, ""


def _load_fleet() -> dict[str, Any]:
    try:
        with FLEET_PATH.open() as f:
            data = json.load(f)
        return {
            "title": data.get("title", "HONEYCOMB"),
            "nodes": data.get("nodes", []),
            "links": data.get("links", []),
        }
    except Exception:
        return {"title": "HONEYCOMB", "nodes": [], "links": []}


def _http_models(base_url: str, models_path: str) -> tuple[bool, list[str], float | None]:
    import urllib.request

    url = base_url.rstrip("/") + (models_path if models_path.startswith("/") else "/" + models_path)
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(url, timeout=3.0) as resp:
            raw = resp.read()
        ms = (time.perf_counter() - t0) * 1000
        data = json.loads(raw.decode() or "{}")
        models = [m.get("id") for m in data.get("data", []) if m.get("id")]
        return True, models, ms
    except Exception:
        return False, [], None


def _ssh_metrics(host: str) -> dict[str, Any] | None:
    cmd = (
        "free -m | awk '/^Mem:/{print $3, $2}'; "
        "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits"
    )
    code, out = _run(["ssh", *SSH_OPTS, host, cmd], timeout=7)
    if code != 0:
        return None
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    metrics: dict[str, Any] = {}
    if lines:
        parts = lines[0].split()
        if len(parts) == 2 and all(p.isdigit() for p in parts):
            metrics["memUsedMB"] = int(parts[0])
            metrics["memTotalMB"] = int(parts[1])
    if len(lines) > 1 and lines[1].lstrip("-").isdigit():
        metrics["gpuUtilPct"] = int(lines[1])
    return metrics or None


def _vllm_metrics(base_url: str) -> dict[str, Any]:
    import urllib.request

    out: dict[str, Any] = {}
    try:
        with urllib.request.urlopen(base_url.rstrip("/") + "/metrics", timeout=3.0) as resp:
            text = resp.read().decode()
    except Exception:
        return out

    def value(metric: str) -> float | None:
        for line in text.splitlines():
            if line.startswith(metric):
                try:
                    return float(line.rsplit(" ", 1)[1])
                except Exception:
                    return None
        return None

    kv = value("vllm:kv_cache_usage_perc")
    if kv is not None:
        out["kvCachePct"] = kv * 100
    gen = value("vllm:generation_tokens_total")
    if gen is not None:
        out["genTokensTotal"] = gen
    return out


# node_id -> (timestamp, generation_tokens_total) for tok/s deltas
_gen_history: dict[str, tuple[float, float]] = {}


def _probe_vllm_ssh(node: dict[str, Any]) -> dict[str, Any]:
    host = node.get("sshHost")
    ssh_ok = False
    if host:
        code, _ = _run(["ssh", *SSH_OPTS, host, "echo", "ok"], timeout=6)
        ssh_ok = code == 0
    infer_ok, models, latency = _http_models(node["baseURL"], node.get("modelsPath", "/v1/models"))

    metrics = _ssh_metrics(host) if (host and ssh_ok) else None
    if infer_ok:
        vm = _vllm_metrics(node["baseURL"])
        if vm:
            metrics = {**(metrics or {}), **vm}
            gen = vm.get("genTokensTotal")
            if gen is not None:
                now = time.time()
                prev = _gen_history.get(node["id"])
                if prev and gen >= prev[1] and now - prev[0] > 0.5:
                    metrics["genTokPerSec"] = (gen - prev[1]) / (now - prev[0])
                _gen_history[node["id"]] = (now, gen)

    health = "online" if ssh_ok else ("online" if infer_ok else "offline")
    parts = []
    if ssh_ok:
        parts.append("ssh")
    if infer_ok:
        parts.append("vllm · " + (models[0].split("/")[-1][:24] if models else "idle"))
    else:
        parts.append("inference idle")
    badge = "SSH+vLLM" if (ssh_ok and infer_ok) else ("SSH" if ssh_ok else ("API" if infer_ok else "DOWN"))
    return {
        "health": health,
        "models": models,
        "inferenceOK": infer_ok,
        "detail": " · ".join(parts) if parts else "unreachable",
        "latencyMs": latency,
        "metrics": metrics,
        "pathBadge": badge,
    }


def _probe_lmstudio_hub(node: dict[str, Any]) -> dict[str, Any]:
    infer_ok, models, latency = _http_models(node["baseURL"], node.get("modelsPath", "/v1/models"))
    chat_models = [m for m in models if "embed" not in m.lower()]
    return {
        "health": "online",  # the hub runs this gateway
        "models": chat_models,
        "inferenceOK": infer_ok,
        "detail": "hub · " + ("lms :1234" if infer_ok else "LM Studio server off"),
        "latencyMs": latency,
        "metrics": None,
        "pathBadge": "LMS" if infer_ok else "HUB",
    }


def _probe_lmlink_peer(node: dict[str, Any]) -> dict[str, Any]:
    peer = node.get("lmLinkPeer") or node.get("hostname") or node["name"]
    lms = _lms_path()
    link_ok = False
    loaded: list[str] = []
    if lms:
        code, out = _run([lms, "link", "status"], timeout=8)
        if code == 0:
            low = out.lower()
            link_ok = peer.lower() in low and ("connected" in low or "online" in low)
        code, out = _run([lms, "ps"], timeout=8)
        if code == 0:
            for line in out.splitlines():
                if peer.lower() in line.lower():
                    token = line.strip().split()
                    if token and len(token[0]) > 2:
                        loaded.append(token[0])
    health = "online" if link_ok else "offline"
    return {
        "health": health,
        "models": loaded,
        "inferenceOK": link_ok,
        "detail": (f"lm-link · {peer}" if link_ok else f"{peer} not in link mesh")
        + (f" · {len(loaded)} loaded" if loaded else ""),
        "latencyMs": None,
        "metrics": None,
        "pathBadge": "LM LINK" if link_ok else "DOWN",
    }


def _probe_http_only(node: dict[str, Any]) -> dict[str, Any]:
    infer_ok, models, latency = _http_models(node["baseURL"], node.get("modelsPath", "/v1/models"))
    return {
        "health": "online" if infer_ok else "offline",
        "models": models,
        "inferenceOK": infer_ok,
        "detail": "api" if infer_ok else "API not answering",
        "latencyMs": latency,
        "metrics": None,
        "pathBadge": "API" if infer_ok else "DOWN",
    }


_PROBES = {
    "vllm-ssh": _probe_vllm_ssh,
    "lmstudio-hub": _probe_lmstudio_hub,
    "lmlink-peer": _probe_lmlink_peer,
    "http-only": _probe_http_only,
}


def _probe_one(node: dict[str, Any]) -> None:
    probe = _PROBES.get(node.get("probe", "http-only"), _probe_http_only)
    try:
        result = probe(node)
    except Exception as e:
        result = {
            "health": "unknown",
            "models": [],
            "detail": f"probe error: {e}",
            "latencyMs": None,
            "metrics": None,
            "pathBadge": "?",
        }
    import collections

    now = time.time()
    nid = node["id"]
    with _lock:
        prev = _status.get(nid, {}).get("health")
        if prev is not None and prev != result["health"]:
            _last_change[nid] = now
        _status[nid] = result
        hist = _history.setdefault(nid, collections.deque(maxlen=500))
        hist.append((now, result["health"], result.get("latencyMs")))
        while hist and now - hist[0][0] > HISTORY_WINDOW_SEC:
            hist.popleft()


def _refresh_loop() -> None:
    global _fleet
    while True:
        fleet = _load_fleet()
        with _lock:
            _fleet = fleet
        futures = [_pool.submit(_probe_one, n) for n in fleet["nodes"] if n.get("id")]
        for f in futures:
            try:
                f.result(timeout=30)
            except Exception:
                pass
        time.sleep(PROBE_INTERVAL_SEC)


def start_prober() -> None:
    threading.Thread(target=_refresh_loop, name="node-prober", daemon=True).start()


def snapshot(activity: dict[str, Any]) -> dict[str, Any]:
    """Full /nodes payload. `activity` = gateway activity_snapshot()."""
    with _lock:
        fleet = dict(_fleet)
        status = {k: dict(v) for k, v in _status.items()}

    ring = [(0, -1), (-1, 0), (1, 0), (0, 1), (-1, 1), (1, -1), (-2, 1), (2, -1)]
    taken = {tuple(n["axial"]) for n in fleet["nodes"] if isinstance(n.get("axial"), list)}
    spare = [p for p in ring if p not in taken]

    nodes_out = []
    for n in fleet["nodes"]:
        nid = n.get("id")
        if not nid:
            continue
        if not isinstance(n.get("axial"), list):
            n = {**n, "axial": list(spare.pop(0)) if spare else [0, 0]}
        st = status.get(
            nid,
            {"health": "unknown", "models": [], "detail": "probing…",
             "latencyMs": None, "metrics": None, "pathBadge": "?"},
        )
        # LIT: backend activity + alias filter, same rules as the Mac app
        lit = False
        bid = n.get("gatewayBackend")
        if bid and bid in activity and activity[bid].get("active"):
            aliases = n.get("litAliases")
            if aliases:
                lit = activity[bid].get("last_alias") in aliases
            else:
                lit = True
        if lit:
            st["pathBadge"] = "LIT"
        with _lock:
            hist = list(_history.get(nid, []))
            changed = _last_change.get(nid)
            doctor_report = _doctor.get(nid)
        latency_series = [h[2] or 0 for h in hist[-60:]]
        nodes_out.append(
            {
                "id": nid,
                "name": n.get("name", nid),
                "role": n.get("role", ""),
                "shortLabel": n.get("shortLabel", ""),
                "hub": bool(n.get("hub")),
                "axial": n.get("axial"),
                "lit": lit,
                "latencySeries": latency_series,
                "lastChange": changed,
                "doctor": doctor_report,
                "canPing": bool(n.get("pingAlias")),
                "canDoctor": bool(n.get("doctorCommand") and n.get("sshHost")),
                "canControl": bool(n.get("container") and n.get("sshHost")),
                **st,
            }
        )
    return {"title": fleet["title"], "links": fleet["links"], "nodes": nodes_out}


# ---------------------------------------------------------------------------
# Control actions (called by the gateway's POST /control/* routes)


def _find_node(node_id: str) -> dict[str, Any] | None:
    with _lock:
        for n in _fleet["nodes"]:
            if n.get("id") == node_id:
                return dict(n)
    return None


def action_ping(node_id: str, gateway_port: int) -> dict[str, Any]:
    """One-shot prompt through the gateway using the node's alias."""
    import urllib.request

    node = _find_node(node_id)
    if not node or not node.get("pingAlias"):
        return {"ok": False, "error": "node has no pingAlias"}
    body = json.dumps(
        {
            "model": node["pingAlias"],
            "messages": [{"role": "user", "content": "Reply with the single word: pong"}],
            "max_tokens": 256,
            "stream": False,
        }
    ).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{gateway_port}/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = json.loads(resp.read().decode())
        ms = (time.perf_counter() - t0) * 1000
        msg = (data.get("choices") or [{}])[0].get("message") or {}
        content = (msg.get("content") or msg.get("reasoning") or "").strip()
        toks = (data.get("usage") or {}).get("completion_tokens")
        return {
            "ok": True,
            "ms": round(ms),
            "tokPerSec": round(toks / (ms / 1000), 1) if toks and ms > 0 else None,
            "snippet": content[:60],
        }
    except Exception as e:
        return {"ok": False, "error": str(e)[:200]}


def action_doctor(node_id: str) -> dict[str, Any]:
    """Run the node's doctorCommand over SSH; cache and return the report."""
    node = _find_node(node_id)
    if not node or not (node.get("doctorCommand") and node.get("sshHost")):
        return {"ok": False, "error": "node has no doctorCommand"}
    code, out = _run(
        ["ssh", *SSH_OPTS, node["sshHost"], node["doctorCommand"]], timeout=120
    )
    report: dict[str, Any] = {"ts": time.time(), "findings": [], "error": None}
    try:
        data = json.loads(out)
        for f in data.get("findings", []):
            report["findings"].append(
                {
                    "ruleID": f.get("rule_id", "?"),
                    "title": f.get("title", ""),
                    "severity": f.get("severity", "info"),
                    "action": (f.get("recommended_actions") or [""])[0],
                }
            )
    except Exception:
        report["error"] = f"doctor failed (exit {code})"
    with _lock:
        _doctor[node_id] = report
    return {"ok": report["error"] is None, **report}


def action_container(node_id: str, verb: str) -> dict[str, Any]:
    """docker start/stop of the node's configured container over SSH."""
    if verb not in ("start", "stop"):
        return {"ok": False, "error": "verb must be start or stop"}
    node = _find_node(node_id)
    if not node or not (node.get("container") and node.get("sshHost")):
        return {"ok": False, "error": "node has no container"}
    code, out = _run(
        ["ssh", *SSH_OPTS, node["sshHost"], "docker", verb, node["container"]],
        timeout=60 if verb == "stop" else 40,
    )
    if code == 0:
        msg = (
            "container starting — model load takes a few minutes"
            if verb == "start"
            else "container stopped"
        )
        return {"ok": True, "message": msg}
    return {"ok": False, "error": f"{verb} failed (exit {code}) {out.strip()[:120]}"}
