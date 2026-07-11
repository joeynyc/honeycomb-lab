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
