# Flow Coach bridge runbook

The bridge is deliberately not deployed by this repository change. Deployment needs Alex's Cloudflare approval and fresh secrets entered out of band.

## Local setup

```bash
cd bridge-worker
npm ci
cp .dev.vars.example .dev.vars
npm run check
npm test
npm run dev
```

Use separate long random values for `FLOW_COACH_ACTIONS_SECRET` and `FLOW_COACH_DEVICE_SECRET`. `.dev.vars` is ignored. Never put a real secret, coach snapshot, routine, patch, or request header in source, an issue, a command transcript, or a log message.

## Pre-deploy gate

1. Complete #46's private-GPT desktop and iOS capability test.
2. Confirm the initial Flow sharing tier and that the Cloudflare account/billing and EU Durable Object are acceptable.
3. Review the production OpenAPI schema and private-GPT instructions against the final hostname.
4. Run `npm run check`, `npm test`, and `npm run deploy:dry-run`.
5. Confirm `wrangler.jsonc` still uses `new_sqlite_classes` and the Worker calls `FLOW_COACH.jurisdiction("eu")` before constructing the singleton ID.

## First deployment

```bash
npx wrangler login
npx wrangler secret put FLOW_COACH_ACTIONS_SECRET
npx wrangler secret put FLOW_COACH_DEVICE_SECRET
npx wrangler deploy
```

Do not add plaintext secret bindings to `wrangler.jsonc`. The Worker returns `503` for an edge whose secret is absent and `401` for the wrong credential. The Actions credential cannot call device routes and the device credential cannot call Actions routes.

## Rotation

This foundation exposes one active secret per edge. Rotate one boundary at a time: create the replacement value, update its only client, write the corresponding Worker secret, deploy, and immediately verify both an allowed request and a rejected old credential. Rotate the other boundary separately. A dual-secret overlap can be added before production if zero-downtime rotation becomes important; do not reuse one secret across both edges.

## Data deletion and teardown

Delete one snapshot with `DELETE /device/snapshots/{contextId}`. This also removes remote proposals derived from it. Delete all mailbox data with authenticated `DELETE /device/data` before dismantling the Worker. A remote delete cannot retract a patch already saved in Flow's local inbox.

For full teardown:

1. Call `DELETE /device/data` and verify it succeeds.
2. Remove the private GPT Action and its credential.
3. Delete both Worker secrets with Wrangler.
4. Delete the Worker only after the mailbox is empty.
5. Confirm in the Cloudflare dashboard that the Worker, Durable Object namespace/data, routes, custom domain, logs, and secrets are gone.

Do not treat deleting only the Worker script as evidence that Durable Object data was removed.

## Operational boundary

The Worker logs no coach payloads or credentials. Cloudflare invocation metadata and control-plane residency are separate from the Durable Object's EU storage jurisdiction; do not make a broader residency claim without reviewing the account configuration. Production monitoring should use status counts, durations, and opaque IDs only.
