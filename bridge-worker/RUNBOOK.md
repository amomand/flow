# Flow Coach bridge runbook

Deployment needs Alex's Cloudflare approval and fresh secrets entered out of band. The #46 connector spike passed on a fixture-only primary deployment; the production shape (#38) replaces the spike's no-auth MCP mount with OAuth 2.1, described under "Claude connector (OAuth)" below.

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

## Claude connector (OAuth, #38)

The MCP edge mounts at `/mcp` and requires an OAuth 2.1 bearer token. Tokens are issued by the Worker itself (`@cloudflare/workers-oauth-provider`): Claude registers a client dynamically, sends the person to `/oauth/authorize`, and the consent page asks for that deployment's connect phrase before granting `coach:read` and `patch:propose`. Grants, refresh tokens, and registered clients live in that environment's `OAUTH_KV` namespace, so nothing OAuth-shaped is shared between people.

`FLOW_COACH_CONNECT_SECRET` is the consent page's whole authentication: at least 32 fresh random characters (`openssl rand -hex 32`), never reused from another secret or person, handed only to the one person allowed to connect to that mailbox. The page fails closed (503) while it is unset or too short.

To connect a person's Claude:

1. In Claude (Settings, Connectors, Add custom connector) add the person-specific URL `https://<their-host>/mcp`. Claude discovers the OAuth endpoints itself; leave any manual auth fields empty.
2. Claude opens the consent page; enter that deployment's connect phrase and approve.
3. Confirm the six tools appear and a read works before any real data is synced.

To disconnect: remove the connector in Claude, then rotate the connect phrase. To force-revoke server-side without the client's cooperation, delete that environment's grants in `OAUTH_KV` (`npx wrangler kv key list --binding OAUTH_KV --env <env>` and delete the listed grant/token keys), then rotate the connect phrase.

## Real-data pre-deploy gate

The primary Worker may be deployed with temporary credentials and synthetic fixtures to complete #46. Before either mailbox receives real data:

1. Confirm the #46 spike's leftovers are gone from any existing deployment: its retained fixture deleted, the retired `FLOW_COACH_MCP_SPIKE_TOKEN` secret deleted, and the temporary credentials rotated.
2. Confirm the initial Flow sharing tier and that the Cloudflare account/billing and EU Durable Object are acceptable.
3. Review each person's connector configuration against the final hostname.
4. Run `npm run check`, `npm test`, and `npm run deploy:dry-run`; the deploy script validates both `primary` and `partner` explicitly.
5. Confirm `wrangler.jsonc` still gives each environment its own Durable Object binding, mailbox ID, and `OAUTH_KV` namespace, uses `new_sqlite_classes`, and the Worker calls `FLOW_COACH.jurisdiction("eu")` before constructing the configured mailbox ID.
6. Choose separate hostnames and per-person connector configurations for the two environments.

## First household deployment

After the primary fixture proof passes, authenticate Wrangler and deploy/configure one environment at a time. The primary environment may already exist from #46; rotate its temporary credentials before pairing Flow. Do not deploy the root `flow-coach-bridge` Worker in production.

```bash
npx wrangler login
npx wrangler kv namespace create OAUTH_KV --env primary    # paste the id into wrangler.jsonc
npx wrangler deploy --env primary
npx wrangler secret put FLOW_COACH_ACTIONS_SECRET --env primary
npx wrangler secret put FLOW_COACH_DEVICE_SECRET --env primary
npx wrangler secret put FLOW_COACH_CONNECT_SECRET --env primary
npx wrangler kv namespace create OAUTH_KV --env partner    # paste the id into wrangler.jsonc
npx wrangler deploy --env partner
npx wrangler secret put FLOW_COACH_ACTIONS_SECRET --env partner
npx wrangler secret put FLOW_COACH_DEVICE_SECRET --env partner
npx wrangler secret put FLOW_COACH_CONNECT_SECRET --env partner
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

The MCP edge rotates differently because the connect phrase is not a bearer credential: rotating `FLOW_COACH_CONNECT_SECRET` stops new authorisations but leaves existing grants and refresh tokens valid. To rotate a person's MCP access fully, rotate the phrase, delete the grant and token keys in that environment's `OAUTH_KV`, and re-approve the connector once with the new phrase. Access tokens expire after an hour on their own; refresh tokens are what the KV deletion revokes.

## Data deletion and teardown

Delete one snapshot with `DELETE /device/snapshots/{contextId}`. This also removes remote proposals derived from it. Delete all data for one mailbox with that environment's authenticated `DELETE /device/data` before dismantling its Worker. A remote delete cannot retract a patch already saved in Flow's local inbox and must not affect the other environment.

For full teardown:

1. Call `DELETE /device/data` and verify it succeeds.
2. Remove the coach connector configuration in Claude.
3. Delete that environment's `OAUTH_KV` namespace so every grant, refresh token, and registered client dies with it.
4. Delete the environment's Worker secrets with Wrangler.
5. Delete that environment's Worker only after its mailbox is empty.
6. Confirm in the Cloudflare dashboard that the Worker, Durable Object namespace/data, KV namespace, routes, custom domain, logs, and secrets are gone.

Do not treat deleting only the Worker script as evidence that Durable Object data was removed.

## Operational boundary

The Worker logs no coach payloads or credentials. Cloudflare invocation metadata and control-plane residency are separate from the Durable Object's EU storage jurisdiction; do not make a broader residency claim without reviewing the account configuration. Production monitoring should use status counts, durations, and opaque IDs only.
