---
name: verify
description: Run and drive the Flow Coach bridge Worker locally to verify changes end to end over real HTTP.
---

# Verify the bridge Worker

Surface: an HTTP server (Cloudflare Worker). Drive it with wrangler dev plus the smoke script; do not import src modules directly.

## Launch

```bash
cd bridge-worker
cp .dev.vars.example .dev.vars   # then replace values; FLOW_COACH_LOCAL_TEST must stay "true" locally
npx wrangler dev --port 8787     # ready when GET /healthz returns {"ok":true}, ~1s
```

`FLOW_COACH_MCP_SPIKE_TOKEN` must be at least 32 characters or the `/mcp/<token>` edge stays closed (404).

## Drive

The smoke script exercises both edges end to end with fixture data and cleans up after itself:

```bash
export FLOW_COACH_ACTIONS_SECRET=... FLOW_COACH_DEVICE_SECRET=... FLOW_COACH_MCP_SPIKE_TOKEN=...
npm run smoke:remote -- http://127.0.0.1:8787
```

For MCP-specific probing, POST single JSON-RPC messages to `/mcp/<token>` (stateless; no session id, no SSE):

```bash
curl -s -X POST http://127.0.0.1:8787/mcp/$TOKEN -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

Then `tools/list` and `tools/call`. Fixture data for device uploads lives at `../bridge-prototype/fixtures/coach-context.json`; snapshot envelopes need all four dataTiers or the sharing-tier hardening 422s.

## Gotchas

- `.dev.vars` is gitignored; never commit real secrets.
- Domain errors come back as tool results with `isError: true` (HTTP 200), not JSON-RPC errors.
- Notifications (no `id`) return 202 with an empty body.
