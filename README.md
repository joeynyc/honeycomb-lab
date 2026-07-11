# Honeycomb Lab

Personal macOS control plane + OpenAI gateway for Joey’s local AI fleet.

## Architecture

```
Cursor / Hermes / apps
        │
        ▼
  Mac mini :4000   ← gateway (this repo)
        │
   ┌────┼────────────┐
   ▼    ▼            ▼
 gx10  JoeyDGX    LM Studio
 peer  main       + LM Link → PC 4080
```

## Run the map (SwiftUI app)

Installed app (real bundle, proper dock icon):

```bash
open /Applications/Honeycomb.app
```

Rebuild + repackage + relaunch after code changes:

```bash
cd ~/dev/Honeycomb
./Scripts/compile_and_run.sh          # packages Honeycomb.app and launches it
cp -R Honeycomb.app /Applications/    # refresh the installed copy
```

Dev loop without packaging (generic dock icon):

```bash
swift run Honeycomb
```

## Run the gateway (API)

The gateway runs automatically via launchd (`~/Library/LaunchAgents/com.joeyrodriguez.honeycomb-gateway.plist`):
starts at login, restarts if it dies, logs to `~/Library/Logs/honeycomb-gateway.log`.

```bash
# manage the service
launchctl kickstart -k gui/$UID/com.joeyrodriguez.honeycomb-gateway   # restart (e.g. after config.json edits)
launchctl bootout gui/$UID/com.joeyrodriguez.honeycomb-gateway        # stop
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.joeyrodriguez.honeycomb-gateway.plist  # start again

# manual run (only if the service is stopped)
cd ~/dev/Honeycomb/gateway && ./start.sh
# → http://127.0.0.1:4000/v1
```

Honeycomb.app is also a **login item** — the map and the wire both come up on their own after a reboot.

| Alias | Backend |
|-------|---------|
| `spark-peer` (default) | gx10 vLLM |
| `spark-main` | JoeyDGX vLLM (when up) |
| `pc-4080` / `local-lms` | LM Studio on Mini (LM Link to ZeroCool) |

```bash
curl -s http://127.0.0.1:4000/health | jq
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"spark-peer","messages":[{"role":"user","content":"hi"}],"max_tokens":64}'
```

**Cursor / OpenAI-compatible tools:** base URL `http://127.0.0.1:4000/v1`, any API key.

## Nodes (truth)

| Node | Role | Connection | Inference |
|------|------|------------|-----------|
| JoeyDGX | Main Spark | NVIDIA Sync SSH | vLLM `:8000` when serving |
| gx10 | Peer Spark | Sync SSH | vLLM (e.g. Qwen3.6-35B NVFP4) |
| Mac mini | Hub | This machine | LM Studio `:1234` |
| PC 4080 | Desktop GPU | LM Link peer ZeroCool | Load model on PC |

## Map features

- **Metrics** (Spark nodes): GPU %, unified memory, vLLM KV-cache, active
  requests, tok/s — inspector bars go amber above 85%.
- **TRAFFIC feed**: last gateway requests (alias, model, tokens, duration)
  under the map; FEED toggle in the top bar.
- **History**: hour of health+latency per node (TREND sparkline, CHANGED row),
  persisted to `~/Library/Application Support/Honeycomb/history.json`.
  macOS notification when a node goes offline / comes back.
- **SERVE / STOP** (Spark nodes): start/stop the node's inference Docker
  container over SSH, with confirmation. Container names in
  `~/Library/Application Support/Honeycomb/control.json`.

## PING diagnostic

Select a hex → **PING** in the inspector. Fires one tiny prompt through the
gateway using that node's alias and shows latency · tok/s · response snippet
inline. Rides the same wire as real clients, so the hex goes LIT — a one-click
self-test of gateway + backend + model.

## Node “LIT” (traffic pulse)

When something (OMP, Cursor, curl) hits the **gateway**, Honeycomb lights the hex that received traffic for ~8s:

```bash
# Peer Spark lights up
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"spark-peer","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```

Direct hits to gx10 `:8000` (bypassing the gateway) will **not** light the map.

## Notes

- JoeyDGX is **main**; gx10 is **peer**.
- Gateway is stdlib Python only (no pip deps).
- Daily loop: **map (Honeycomb)** + **wire (gateway :4000)** + **agent (OMP/Cursor)**.

## Use with your own fleet

Node definitions live in `~/Library/Application Support/Honeycomb/fleet.json` (created from the bundled default on first launch; edit it and relaunch). Copy `fleet.example.json` as a starting point.

**Probe types:**
- `vllm-ssh` — GPU box running vLLM, SSH reachability = online.
- `lmstudio-hub` — the Mac running the app, serving via LM Studio.
- `lmlink-peer` — a remote GPU reached through the hub's LM Studio via LM Link; set `lmLinkPeer` to the peer's device name.
- `http-only` — any OpenAI-compatible endpoint.

**Fields:** `gatewayBackend` / `pingAlias` map nodes to backends in `gateway/config.json` so hexes light on traffic; `container` enables SERVE/STOP over SSH (docker start/stop); `hub: true` marks the center node; axial `[q,r]` optionally pins map position; `links` adds extra edges. The gateway's backends/aliases are configured separately in `gateway/config.json`.

Set `HONEYCOMB_FLEET` env var to override the fleet file path.
