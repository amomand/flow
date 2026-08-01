# Flow Coach bridge Worker

Local, deployment-ready foundation for phases [#38](https://github.com/amomand/flow/issues/38) and [#39](https://github.com/amomand/flow/issues/39).

It is a single-person mailbox Worker backed by one EU-jurisdiction, SQLite Durable Object. The same code is deployed independently for each person; the checked-in `primary` and `partner` Wrangler environments create separate Worker services, Durable Object storage, credentials, and coach-client configurations. The Worker exposes separately authenticated edges:

- `/actions/*` reads exact coach snapshots, validates routine patches, and stores draft proposals. Its private-GPT schema and instructions remain in [`chatgpt`](chatgpt) as fallback smoke coverage.
- `/device/*` uploads/deletes snapshots, pulls pending patches, and acknowledges lifecycle state.
- `/mcp` speaks MCP (stateless Streamable HTTP) for compatible hosts including Claude and ChatGPT, translating the same six coach operations onto the `/actions/*` domain routes with provider-neutral `mcp` provenance. It is gated by OAuth 2.1 (`@cloudflare/workers-oauth-provider`: dynamic client registration, authorization code with S256 PKCE, refresh tokens in `OAUTH_KV`), with `coach:read` and `patch:propose` scopes advertised and enforced per tool. Consent at `/oauth/authorize` is granted by entering the per-person `FLOW_COACH_CONNECT_SECRET`; the #46 spike's no-auth `/mcp/<token>` mount is gone.

The Durable Object keeps multiple unexpired snapshots, correlates every proposal with the exact snapshot read, deduplicates proposal retries, expires records by alarm, and removes patch payloads at terminal states. It cannot mutate a Flow routine.

`FLOW_COACH_MAILBOX_ID` is trusted deployment configuration used to select the Durable Object. It is not a secret, a display name, or an authorization mechanism, and no request may override it. Do not point two people's Flow installations or coach clients at one deployment. A future authenticated router can select among mailbox objects without changing the stored schema; the first household deployment deliberately avoids that account-system complexity.

The production environments are deployed. The Claude connector proof passed on desktop and iOS (#46), the Flow sync client shipped (#39), and the two-environment isolation proof runs as one command (`npm run smoke:isolation`). Per the pivot recorded on #37, MCP remains the primary LLM-facing edge and uses this domain store rather than a provider-specific fork. Issue #49 proved this same endpoint from ChatGPT and closed: it works from ChatGPT Work, which has no access to a person's ordinary ChatGPT memory, and connectors do not reach ordinary Chat or mobile. Compatibility is real; the product experience is not there, so Claude stays the coach surface. The private-GPT Actions package remains a fallback smoke surface, not the target integration.

See [RUNBOOK.md](RUNBOOK.md) for deploying, connecting a person's MCP client, the current ChatGPT surface boundary, rotation, and teardown.

## Local verification

```bash
npm ci
npm run check
npm test
npm run deploy:dry-run
```

See `RUNBOOK.md` before any real deployment or secret change.

`npm run smoke:remote -- https://...` verifies a deployed Worker end to end without using real Flow data.
