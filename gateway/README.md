# Honeycomb Gateway

Single OpenAI-compatible API on the Mac mini for the whole lab.

```
http://127.0.0.1:4000/v1
```

## Service

Gateway runs automatically under launchd:

- **LaunchAgent:** `~/Library/LaunchAgents/com.joeyrodriguez.honeycomb-gateway.plist` (starts at login, KeepAlive restarts on crash)
- **Log:** `~/Library/Logs/honeycomb-gateway.log`
- **Restart after config changes:** `launchctl kickstart -k gui/$UID/com.joeyrodriguez.honeycomb-gateway`
- **Manual fallback:** `cd ~/dev/Honeycomb/gateway && ./start.sh` (only if service is stopped)

## Aliases

| Model id | Routes to |
|----------|-----------|
| `spark-peer` | gx10 vLLM (default) |
| `spark-main` | JoeyDGX vLLM (when serving) |
| `pc-4080` / `local-lms` | LM Studio on Mini (includes LM Link remote models) |
| `gx10/<id>` | explicit peer model |
| `lms/<id>` | explicit LM Studio model |

Aliases with no pinned upstream model auto-pick the backend's first chat-capable model (embedding models are skipped).

## Health

```bash
curl -s http://127.0.0.1:4000/health | jq
curl -s http://127.0.0.1:4000/v1/models | jq
```

## Chat (Cursor / Hermes / etc.)

Base URL: `http://127.0.0.1:4000/v1`  
API key: any string (ignored)

```bash
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "spark-peer",
    "messages": [{"role":"user","content":"Say hi in one short sentence."}],
    "max_tokens": 64
  }' | jq
```
