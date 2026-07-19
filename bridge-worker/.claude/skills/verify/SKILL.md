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

`FLOW_COACH_CONNECT_SECRET` must be at least 32 characters or the OAuth consent page stays closed (503). The MCP edge itself mounts at `/mcp` and always requires a bearer token.

## Drive

The smoke script exercises the Actions and device edges end to end with fixture data and cleans up after itself. It also checks OAuth discovery and the tokenless 401; set `FLOW_COACH_MCP_ACCESS_TOKEN` to exercise MCP tool calls too:

```bash
export FLOW_COACH_ACTIONS_SECRET=... FLOW_COACH_DEVICE_SECRET=...
npm run smoke:remote -- http://127.0.0.1:8787
```

To mint an access token locally, walk the OAuth flow (values in `test/oauth-helper.ts` mirror this):

1. `POST /oauth/register` with `{"client_name":"probe","redirect_uris":["https://client.test/callback"],"grant_types":["authorization_code","refresh_token"],"response_types":["code"],"token_endpoint_auth_method":"none"}` → `client_id`.
2. `POST /oauth/authorize?response_type=code&client_id=...&redirect_uri=https://client.test/callback&state=x&code_challenge=<S256(verifier)>&code_challenge_method=S256` with form body `connect_phrase=<FLOW_COACH_CONNECT_SECRET>` → 302; take `code` from the Location header.
3. `POST /oauth/token` with form fields `grant_type=authorization_code&code=...&client_id=...&redirect_uri=...&code_verifier=<verifier>` → `access_token`.

For MCP-specific probing, POST single JSON-RPC messages to `/mcp` with the bearer token (stateless; no session id, no SSE):

```bash
curl -s -X POST http://127.0.0.1:8787/mcp -H "authorization: Bearer $ACCESS_TOKEN" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

Then `tools/list` and `tools/call`. Fixture data for device uploads lives at `../bridge-prototype/fixtures/coach-context.json`; snapshot envelopes need all four dataTiers or the sharing-tier hardening 422s.

## Gotchas

- `.dev.vars` is gitignored; never commit real secrets.
- Domain errors come back as tool results with `isError: true` (HTTP 200), not JSON-RPC errors.
- Notifications (no `id`) return 202 with an empty body.
- Tokens live in the local KV simulation; restarting `wrangler dev` keeps them (state persists under `.wrangler/`), but a fresh checkout needs the flow run again.
