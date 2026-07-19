# Flow Coach bridge Worker

Local, deployment-ready foundation for phases [#38](https://github.com/amomand/flow/issues/38) and [#39](https://github.com/amomand/flow/issues/39).

It is a single-person mailbox Worker backed by one EU-jurisdiction, SQLite Durable Object. The same code is deployed independently for each person; the checked-in `primary` and `partner` Wrangler environments create separate Worker services, Durable Object storage, credentials, and coach-client configurations. The Worker exposes separately authenticated edges:

- `/actions/*` reads exact coach snapshots, validates routine patches, and stores draft proposals.
- `/device/*` uploads/deletes snapshots, pulls pending patches, and acknowledges lifecycle state.
- `/mcp` speaks MCP (stateless Streamable HTTP) for Claude custom connectors, translating the same six coach operations onto the `/actions/*` domain routes with `claude-mcp` provenance. It is gated by OAuth 2.1 (`@cloudflare/workers-oauth-provider`: dynamic client registration, authorization code with S256 PKCE, refresh tokens in `OAUTH_KV`), with `coach:read` and `patch:propose` scopes enforced per tool. Consent at `/oauth/authorize` is granted by entering the per-person `FLOW_COACH_CONNECT_SECRET`; the #46 spike's no-auth `/mcp/<token>` mount is gone.

The Durable Object keeps multiple unexpired snapshots, correlates every proposal with the exact snapshot read, deduplicates proposal retries, expires records by alarm, and removes patch payloads at terminal states. It cannot mutate a Flow routine.

`FLOW_COACH_MAILBOX_ID` is trusted deployment configuration used to select the Durable Object. It is not a secret, a display name, or an authorization mechanism, and no request may override it. Do not point two people's Flow installations or coach clients at one deployment. A future authenticated router can select among mailbox objects without changing the stored schema; the first household deployment deliberately avoids that account-system complexity.

This is not deployed and does not complete either issue. A synthetic remote smoke test and the MCP connector edge live in this directory; the Claude desktop/iOS proof (#46), the Cloudflare account/secrets, the Flow URLSession/Keychain/UI client, and OAuth remain explicit follow-up work. Per the pivot recorded on #37, MCP is the primary LLM-facing edge and uses this domain store rather than a provider-specific fork; the GPT Actions route is deferred to #49, with its artefacts archived on that issue.

## Local verification

```bash
npm ci
npm run check
npm test
npm run deploy:dry-run
```

See `RUNBOOK.md` before any real deployment or secret change.

`npm run smoke:remote -- https://...` verifies a deployed Worker end to end without using real Flow data.
