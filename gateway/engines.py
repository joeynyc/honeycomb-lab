"""Inference-engine knowledge for the web dashboard's node prober.

Python twin of the Swift app's InferenceEngine + ProbeParsers
(Sources/Honeycomb/Services/ProbeParsers.swift) so the browser dashboard
sees the same fleet the Mac app does. Keep the two in sync: match tokens,
default ports, metric names, and lms CLI parsers live here and there.
Stdlib only.
"""

from __future__ import annotations

import json
import re
from typing import Any, NamedTuple


class Engine(NamedTuple):
    name: str          # raw id, matches Swift rawValue ("vllm", "sglang", "llama.cpp")
    label: str         # display name
    match_tokens: tuple[str, ...]  # substrings marking a container image/command
    default_port: int  # port bound when launched without --port
    kv_metric: str     # 0-1 usage ratio gauge on /metrics
    running_metric: str
    gen_metric: str


# Order is detection priority — a vLLM serve of a llama model must match
# vllm, not llama.cpp.
ENGINES: tuple[Engine, ...] = (
    Engine("sglang", "SGLang", ("sglang",), 30000,
           "sglang:token_usage",
           "sglang:num_running_reqs",
           "sglang:generation_tokens_total"),
    Engine("vllm", "vLLM", ("vllm",), 8000,
           "vllm:kv_cache_usage_perc",
           "vllm:num_requests_running",
           "vllm:generation_tokens_total"),
    Engine("llama.cpp", "llama.cpp", ("llama",), 8080,
           "llamacpp:kv_cache_usage_ratio",
           "llamacpp:requests_processing",
           "llamacpp:tokens_predicted_total"),
)

ALL_MATCH_TOKENS: tuple[str, ...] = tuple(
    t for e in ENGINES for t in e.match_tokens
)

_PORT_FLAG = re.compile(r"--port[=\"',\\ \t]+([0-9]{1,5})")


def detect(text: str) -> Engine | None:
    lowered = text.lower()
    for engine in ENGINES:
        if any(token in lowered for token in engine.match_tokens):
            return engine
    return None


def serve_from_docker_inspect(text: str) -> tuple[Engine | None, int | None]:
    """Engine + API port from `docker inspect --format
    '{{json .Config.Entrypoint}} {{json .Config.Cmd}}'` output.

    Handles both arg-array form ("--port","8888") and a bash -lc wrapper
    where the flag lives inside one escaped string. An explicit --port wins;
    otherwise the recognized engine's default. (None, None) when no known
    serve command is visible — callers keep the configured baseURL then.
    """
    engine = detect(text)
    m = _PORT_FLAG.search(text)
    if m:
        port = int(m.group(1))
        if 1 <= port <= 65535:
            return engine, port
    return engine, engine.default_port if engine else None


def metrics_from_prometheus(text: str) -> dict[str, Any]:
    """The handful of engine gauges the map cares about — all three engines'
    names are tried; the sets are disjoint. Keys match the /nodes payload."""
    def value(metrics: list[str]) -> float | None:
        for line in text.splitlines():
            for metric in metrics:
                if line.startswith(metric):
                    try:
                        return float(line.rsplit(" ", 1)[1])
                    except (ValueError, IndexError):
                        return None
        return None

    out: dict[str, Any] = {}
    kv = value([e.kv_metric for e in ENGINES])
    if kv is not None:
        out["kvCachePct"] = kv * 100
    running = value([e.running_metric for e in ENGINES])
    if running is not None:
        out["runningRequests"] = int(running)
    gen = value([e.gen_metric for e in ENGINES])
    if gen is not None:
        out["genTokensTotal"] = gen
    return out


def running_inference_containers(
    docker_ps: str, preferred: str | None = None
) -> list[str]:
    """Names of running inference containers from `docker ps` Names\\tImage
    lines. Host-network serves publish no ports, so match the image against
    the engine tokens, plus the fleet preferred name when it is running."""
    names: list[str] = []
    seen: set[str] = set()
    for line in docker_ps.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t", 1)
        name = parts[0].strip()
        if not name or name in seen:
            continue
        image = (parts[1] if len(parts) > 1 else "").lower()
        is_inference = any(token in image for token in ALL_MATCH_TOKENS)
        if is_inference or (preferred is not None and name == preferred):
            seen.add(name)
            names.append(name)
    return names


def lm_studio_loaded_models(
    text: str,
    device_filter: str | None = None,
    exclude_devices: list[str] | None = None,
) -> list[str]:
    """Loaded models from `lms ps` output, optionally filtered by DEVICE.

    Twin of ProbeParsers.lmStudioLoadedModels. Hub callers pass peer names in
    exclude_devices so LM Link rows are not listed as local; peer callers pass
    device_filter to keep only that peer's rows.
    """
    if "no models are currently loaded" in text.lower():
        return []
    found: list[str] = []
    skip_prefixes = ("IDENTIFIER", "LLM", "EMBEDDING", "To load", "SIZE")
    excluded = exclude_devices or []
    for line in text.splitlines():
        trimmed = line.strip()
        if not trimmed or trimmed.startswith(skip_prefixes):
            continue
        if device_filter is not None:
            if device_filter.lower() not in line.lower():
                continue
        elif any(d.lower() in line.lower() for d in excluded):
            continue
        parts = trimmed.split()
        if parts and len(parts[0]) > 2:
            found.append(parts[0])
    return found


def _is_peer_label(label: str, name: str) -> bool:
    """`- <label>` names the peer: exact, or name then a non-name character
    (`gaming-pc (Windows)`), so peer "pc" doesn't claim "gaming-pc"."""
    if not label.startswith(name):
        return False
    rest = label[len(name):]
    return not rest or not (rest[0].isalnum() or rest[0] in "-_.")


def lm_link_peer_connected(text: str, name: str) -> bool:
    """Whether `lms link status` shows the named peer as connected.

    Twin of ProbeParsers.lmLinkPeerConnected: walk peer blocks (`- <name>`
    then `Status: connected` / `online`). The status value must *start* with
    connected/online so "disconnected" doesn't count. A name with no block
    of its own is not connected; only output with no peer blocks at all
    falls back to whole-word name + un-negated "connected".
    """
    in_peer = False
    saw_peer_block = False
    needle = name.lower()
    for line in text.splitlines():
        t = line.strip()
        if t.startswith("- "):
            saw_peer_block = True
            in_peer = _is_peer_label(t[2:].strip().lower(), needle)
        elif in_peer and t.lower().startswith("status:"):
            value = t[len("status:"):].strip().lower()
            return value.startswith(("connected", "online"))
    # Peer blocks exist but none is this peer: it's not connected.
    if saw_peer_block:
        return False
    # Unrecognized layout: name and "connected" as whole words, not negated.
    low = text.lower()
    return (
        re.search(rf"(?<![\w.-]){re.escape(needle)}(?![\w.-])", low) is not None
        and re.search(r"\bconnected\b", low) is not None
        and re.search(r"\b(not|0|no)\s+connected\b", low) is None
    )


def lm_studio_models_on_device(text: str, device: str) -> list[str]:
    """Model ids listed under a remote device in `lms ls` (DEVICE column).

    Twin of ProbeParsers.lmStudioModelsOnDevice.
    """
    found: list[str] = []
    needle = device.lower()
    for line in text.splitlines():
        if needle not in line.lower():
            continue
        parts = line.split()
        if parts and len(parts[0]) > 2 and not parts[0].startswith("LLM"):
            found.append(parts[0])
    return found


def models_listing_from_json(raw: bytes | str) -> tuple[list[str], bool]:
    """Model ids plus whether this is an LM Studio loaded-only listing.

    Twin of ProbeParsers.modelListing. `/api/v0/models` items carry `state`
    (`loaded` / `not-loaded`); when any item has `state`, only loaded ids
    are returned and the second value is True so probes do not fall through
    to a disk catalog.
    """
    try:
        data = json.loads(raw if isinstance(raw, str) else raw.decode())
    except Exception:
        return [], False
    if not isinstance(data, dict):
        return [], False
    for key in ("data", "models"):
        items = data.get(key)
        if not isinstance(items, list):
            continue
        dicts = [m for m in items if isinstance(m, dict)]
        if any("state" in m for m in dicts):
            loaded = [
                m.get("id") or m.get("name") or m.get("model")
                for m in dicts
                if str(m.get("state") or "").lower() == "loaded"
            ]
            return [i for i in loaded if i], True
        ids = [m.get("id") or m.get("name") or m.get("model") for m in dicts]
        ids = [i for i in ids if i]
        if ids:
            return ids, False
    return [], False


def models_from_json(raw: bytes | str) -> list[str]:
    """Model ids from a models-listing response: OpenAI /v1/models
    (data[].id), LM Studio (models[].id or /api/v0/models with state),
    or Ollama /api/tags (models[].name / models[].model)."""
    ids, _ = models_listing_from_json(raw)
    return ids
