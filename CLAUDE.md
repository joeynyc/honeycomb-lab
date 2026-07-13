# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Honeycomb is a control plane for a home GPU fleet: a native macOS SwiftUI app plus a zero-dependency Python gateway that exposes one OpenAI-compatible endpoint (`http://<hub>:4000/v1`) routing to vLLM boxes, LM Studio, or any compatible backend.

## Commands

```bash
# Swift app: build only
swift build

# Dev loop: kill running instances, build, package .app, relaunch, verify
./Scripts/compile_and_run.sh            # add --test to run swift test first

# Run tests
swift test

# Distributable release: universal binary, gateway bundled, zipped into dist/
./Scripts/make_release.sh               # ad-hoc signed; APP_IDENTITY=... for real signing

# Gateway (Python stdlib only, no pip install)
cp gateway/config.example.json gateway/config.json   # first time; edit backends + control_token
(cd gateway && ./start.sh)                           # serves http://0.0.0.0:4000
```

`Scripts/package_app.sh` is the single source of packaging logic (bundle assembly, signing, gateway embedding); `compile_and_run.sh` and `make_release.sh` both delegate to it. App name/bundle id/version come from `version.env`.

There is no Xcode project — this is a pure SwiftPM executable (`Package.swift`, macOS 14+, Swift 6). The .app bundle is assembled by script.

## Architecture

Two independent frontends over one fleet, coordinated by config files:

- **Swift app** (`Sources/Honeycomb/`) — probes nodes directly over its own SSH/HTTP; it does NOT go through the gateway for node status. It only calls the gateway for `/health`, `/requests` (traffic feed / LIT pulses), and chat.
- **Gateway** (`gateway/server.py`) — the OpenAI front door: alias routing (`cheap` = cheapest healthy backend, `any` = cheap + failover, custom aliases, `backend/<model>`), request proxying (stream + non-stream), stats. Also serves a self-contained browser dashboard (`gateway/dashboard.html`) at `/`, with `gateway/nodes.py` + `/nodes` + `/control/*` giving browsers the same probe/ping/doctor/container controls the Swift app implements natively. This duplication is deliberate — browser/iPad access without the app.

Key Swift pieces:

- `Services/HealthMonitor.swift` — the core polling engine. Holds observable fleet state and implements the four probe paths, one per node type: `vllm-ssh` (SSH + nvidia-smi + vLLM /metrics), `lmstudio-hub`, `lmlink-peer`, `http-only`. These are genuinely distinct code paths, not variants.
- `Services/ProbeParsers.swift` — pure parsers for probe output (`lms ps`/`lms link status`/`lms ls` text, `free`+`nvidia-smi` output, vLLM Prometheus gauges, models-listing JSON). These are the unit-tested surface (`Tests/HoneycombTests/`); keep new parsing logic here, not inline in HealthMonitor, so it stays testable against fixtures.
- `Services/Subprocess.swift` — shared process runner; all SSH invocations route through it.
- `Services/NodeControl.swift` / `DoctorService.swift` / `PingService.swift` — SERVE/STOP containers over SSH, spark-doctor runs, wire pings.
- `Services/GatewayLauncher.swift` — the app bundles the gateway and can start it (START GATEWAY button).
- `Views/HoneycombCanvas.swift` — the hex map; hex color = health, LIT pulses = live traffic from `/requests`.
- `Theme/LabTheme.swift` — CRT/phosphor color palette used everywhere; amber is reserved for degraded/warning states.

## Configuration (runtime, not in repo)

- `~/Library/Application Support/Honeycomb/fleet.json` — node definitions (see `fleet.example.json`; `HONEYCOMB_FLEET` env var overrides the path). Per-node fields wire features: `gatewayBackend`/`litAliases` (LIT on traffic), `pingAlias` (PING), `container`+`sshHost` (SERVE/STOP), `doctorCommand` (DOCTOR), `hub`, `axial` map position.
- `~/Library/Application Support/Honeycomb/gateway-config.json` — gateway backends, `cheap_order`, `control_token`, `allowed_hosts` (for repo-local runs: `gateway/config.json`).

## Security model (don't weaken)

The gateway targets a trusted LAN/tailnet, no TLS. `/control/*` requires `X-Honeycomb-Token` except from localhost; requests must address the hub by IP literal unless the hostname is in `allowed_hosts` (DNS-rebinding defense); control responses deliberately carry no CORS headers; the example config's `__REPLACE_ME__` token never authorizes.
