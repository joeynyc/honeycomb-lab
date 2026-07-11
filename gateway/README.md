# Honeycomb Gateway

Single OpenAI-compatible API on the Mac mini for the whole lab.

```
http://127.0.0.1:4000/v1
```

## Start

```bash
cd ~/dev/Honeycomb/gateway
./start.sh
```

## Aliases

| Model id | Routes to |
|----------|-----------|
| `spark-peer` | gx10 vLLM (default) |
| `spark-main` | JoeyDGX vLLM (when serving) |
| `pc-4080` / `local-lms` | LM Studio on Mini (includes LM Link remote models) |
| `gx10/<id>` | explicit peer model |
| `lms/<id>` | explicit LM Studio model |

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
