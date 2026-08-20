# Honeycomb Gateway

Single OpenAI-compatible API on the hub for the whole lab.

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
| `cheap` | First healthy backend in `cheap_order` (config) that has a chat model loaded. If `cheap_order` is omitted, backends are tried in declaration order. |
| `any` | Like `cheap`, plus automatic failover: if the backend errors mid-request, retries the next healthy one (non-stream only). Any alias can opt in with `"failover": true` in the request body. |
| *your aliases* | Whatever you define in `config.json` |
| `backend/<model>` | Explicit model on an explicit backend |
| `model@backend` | Same passthrough, opposite order |

Aliases with no pinned upstream model auto-pick the backend's first chat-capable model (embedding models are skipped). Unknown model ids are sent to the first `cheap_order` backend (not a hardcoded lab name).

## Health

```bash
curl -s http://127.0.0.1:4000/health | jq
curl -s http://127.0.0.1:4000/v1/models | jq
```

## Chat (any OpenAI-compatible client)

Base URL: `http://127.0.0.1:4000/v1`  
API key: any string (ignored)

```bash
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "cheap",
    "messages": [{"role":"user","content":"Say hi in one short sentence."}],
    "max_tokens": 64
  }' | jq
```
