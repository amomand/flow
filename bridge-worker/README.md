# Flow Coach bridge Worker

Local, deployment-ready foundation for phases [#38](https://github.com/amomand/flow/issues/38) and [#39](https://github.com/amomand/flow/issues/39).

It is one single-user Cloudflare Worker backed by one EU-jurisdiction, SQLite Durable Object. The Worker exposes separately authenticated edges:

- `/actions/*` reads exact coach snapshots, validates routine patches, and stores draft proposals.
- `/device/*` uploads/deletes snapshots, pulls pending patches, and acknowledges lifecycle state.

The Durable Object keeps multiple unexpired snapshots, correlates every proposal with the exact snapshot read, deduplicates proposal retries, expires records by alarm, and removes patch payloads at terminal states. It cannot mutate a Flow routine.

This is not deployed and does not complete either issue. The Flow URLSession/Keychain/UI client, production OpenAPI file, private-GPT desktop/iOS test, Cloudflare account/secrets, and optional OAuth MCP adapter remain explicit follow-up work. MCP is deferred until the human decision in `docs/flow-coach-bridge-architecture.md`; it will use this domain store rather than a provider-specific fork.

## Local verification

```bash
npm ci
npm run check
npm test
npm run deploy:dry-run
```

See `RUNBOOK.md` before any real deployment or secret change.
