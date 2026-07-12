# Flow Coach bridge runbook

The bridge is deliberately not deployed by this repository change. Deployment needs Alex's Cloudflare approval and fresh secrets entered out of band. A narrower primary-mailbox fixture deployment answers #46 (the Claude connector spike) before any real data or phone pairing; see "Claude connector spike" below.

## Local setup

```bash
cd bridge-worker
npm ci
cp .dev.vars.example .dev.vars
npm run check
npm test
npm run dev
```

Use separate long random values for `FLOW_COACH_ACTIONS_SECRET` and `FLOW_COACH_DEVICE_SECRET`. `FLOW_COACH_MAILBOX_ID` is a non-secret deployment identifier, but it must come from trusted configuration rather than a request. `.dev.vars` is ignored. Never put a real secret, coach snapshot, routine, patch, or request header in source, an issue, a command transcript, or a log message.

The example sets `FLOW_COACH_LOCAL_TEST=true` because workerd cannot emulate jurisdiction-restricted Durable Object namespaces. That binding is for local development only. Never add it to `wrangler.jsonc`, a deployed environment, or a Cloudflare secret.

## Household deployment boundary

The first production shape is one deployment per person, not one shared household mailbox. The checked-in Wrangler environments deploy as separate Worker services:

| Environment | Worker service | Mailbox configuration |
|---|---|---|
| `primary` | `flow-coach-bridge-primary` | `primary-v1` |
| `partner` | `flow-coach-bridge-partner` | `partner-v1` |

Wrangler environments have non-inherited Durable Object bindings and environment-specific secrets. Do not add `script_name` pointing both environments back to the same Worker, reuse either credential, or configure both people's coach clients against one hostname. The mailbox IDs are routing configuration, not person authentication; the separately scoped credentials and service boundary provide authorization.

One Flow installation pairs with one device endpoint. The person operating the matching coach client may be someone else, but proposals still land only in the paired Flow inbox for review. Give each Claude Project and conversation a clear person-specific name so conversational context does not cross the storage boundary.

## Claude connector spike (#46)

The primary Worker may be deployed with temporary credentials and synthetic fixtures to answer #46. The MCP edge mounts at `/mcp/<token>` only when `FLOW_COACH_MCP_SPIKE_TOKEN` is set; the unguessable token is the whole access control for the spike, so it must be at least 32 fresh random characters (`openssl rand -hex 32`), never reused from another secret, and rotated or removed before any real data.

1. Deploy the primary environment and set its secrets, including the spike token:

   ```bash
   npx wrangler deploy --env primary
   npx wrangler secret put FLOW_COACH_ACTIONS_SECRET --env primary
   npx wrangler secret put FLOW_COACH_DEVICE_SECRET --env primary
   npx wrangler secret put FLOW_COACH_MCP_SPIKE_TOKEN --env primary
   ```

2. With the same values exported in the shell, run `FLOW_COACH_KEEP_FIXTURE=true npm run smoke:remote -- https://<primary-host>` so the fixture snapshot survives for the phone test. The smoke test exercises both the REST edge and the MCP edge, including the wrong-token 404.
3. In Claude, add a custom connector (Settings, Connectors, Add custom connector): a clearly synthetic name such as `Flow Coach (fixture)`, URL `https://<primary-host>/mcp/<token>`, no OAuth fields.
4. In one conversation on Claude desktop/web and one on iOS: read the coach context, inspect a routine, discuss a small change, and create one pending patch. Confirm the pending record exists through the device edge.
5. Record on #46: confirmation-prompt wording, per-surface differences, plan-tier behaviour, and whether one chat continues across devices.
6. Tear down: delete the fixture snapshot through the device edge, then rotate or remove the spike token and the temporary credentials.

## Real-data pre-deploy gate

The primary Worker may be deployed with temporary credentials and synthetic fixtures to complete #46. Before either mailbox receives real data:

1. Complete #46's Claude desktop and iOS connector test, then remove its retained fixture and rotate or remove the spike token.
2. Confirm the initial Flow sharing tier and that the Cloudflare account/billing and EU Durable Object are acceptable.
3. Review each person's connector configuration against the final hostname.
4. Run `npm run check`, `npm test`, and `npm run deploy:dry-run`; the deploy script validates both `primary` and `partner` explicitly.
5. Confirm `wrangler.jsonc` still gives each environment its own Durable Object binding and mailbox ID, uses `new_sqlite_classes`, and the Worker calls `FLOW_COACH.jurisdiction("eu")` before constructing the configured mailbox ID.
6. Choose separate hostnames and per-person connector configurations for the two environments.

## First household deployment

After the primary fixture proof passes, authenticate Wrangler and deploy/configure one environment at a time. The primary environment may already exist from #46; rotate its temporary credentials before pairing Flow. Do not deploy the root `flow-coach-bridge` Worker in production.

```bash
npx wrangler login
npx wrangler deploy --env primary
npx wrangler secret put FLOW_COACH_ACTIONS_SECRET --env primary
npx wrangler secret put FLOW_COACH_DEVICE_SECRET --env primary
npx wrangler deploy --env partner
npx wrangler secret put FLOW_COACH_ACTIONS_SECRET --env partner
npx wrangler secret put FLOW_COACH_DEVICE_SECRET --env partner
```

Do not add plaintext secret bindings to `wrangler.jsonc`. The Worker returns `503` when mailbox deployment configuration or an edge secret is absent, and `401` for the wrong credential. The Actions credential cannot call device routes, the device credential cannot call Actions routes, and neither environment's credential should authenticate to the other environment.

Before real data, run a two-environment isolation smoke test with fixture snapshots:

1. Upload a different fixture context to each device endpoint.
2. Verify each Actions endpoint reads only its own fixture.
3. Verify both credentials for `primary` receive `401` from `partner`, and vice versa.
4. Create and pull one proposal in each environment; verify neither appears in the other.
5. Delete all data in one environment; verify the other environment is unchanged.
6. Remove the fixtures and rotate the temporary credentials before pairing either phone.

## Rotation

Each environment exposes one active secret per edge. Rotate one boundary in one environment at a time: create the replacement value, update its only client, write the corresponding environment-specific Worker secret, deploy, and immediately verify both an allowed request and a rejected old credential. Rotate the other boundary separately. A dual-secret overlap can be added before production if zero-downtime rotation becomes important; do not reuse a secret across edges or people.

## Data deletion and teardown

Delete one snapshot with `DELETE /device/snapshots/{contextId}`. This also removes remote proposals derived from it. Delete all data for one mailbox with that environment's authenticated `DELETE /device/data` before dismantling its Worker. A remote delete cannot retract a patch already saved in Flow's local inbox and must not affect the other environment.

For full teardown:

1. Call `DELETE /device/data` and verify it succeeds.
2. Remove the coach connector configuration and its credential.
3. Delete both Worker secrets for that environment with Wrangler.
4. Delete that environment's Worker only after its mailbox is empty.
5. Confirm in the Cloudflare dashboard that the Worker, Durable Object namespace/data, routes, custom domain, logs, and secrets are gone.

Do not treat deleting only the Worker script as evidence that Durable Object data was removed.

## Operational boundary

The Worker logs no coach payloads or credentials. Cloudflare invocation metadata and control-plane residency are separate from the Durable Object's EU storage jurisdiction; do not make a broader residency claim without reviewing the account configuration. Production monitoring should use status counts, durations, and opaque IDs only.
