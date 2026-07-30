# Flow Coach bridge runbook

Both environments are deployed and carrying real data for one person. The spike's no-auth MCP mount is gone, replaced by the OAuth 2.1 edge described under "Claude connector (OAuth)" below.

| Environment | Hostname | Mailbox | State |
|---|---|---|---|
| `primary` | `flow-coach-bridge-primary.aomand.workers.dev` | `primary-v1` | paired, in use |
| `partner` | `flow-coach-bridge-partner.aomand.workers.dev` | `partner-v1` | deployed, not yet paired |

Credentials live only in the operator's password manager. Three secrets per environment, all generated with `openssl rand -hex 32` and never reused across edges or people: `FLOW_COACH_DEVICE_SECRET` for the paired Flow installation, `FLOW_COACH_CONNECT_SECRET` for the connector consent page, and `FLOW_COACH_ACTIONS_SECRET` for smoke tests and that person's private GPT when enabled. Pipe them in with `printf '%s'` rather than `echo`, because a trailing newline inside a stored secret produces 401s that are miserable to diagnose.

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

One Flow installation pairs with one device endpoint. The person operating the matching coach client may be someone else, but proposals still land only in the paired Flow inbox for review. Give each Claude Project or private GPT and its conversations a clear person-specific name so conversational context does not cross the storage boundary.

## Claude connector (OAuth, #38)

The MCP edge mounts at `/mcp` and requires an OAuth 2.1 bearer token. Tokens are issued by the Worker itself (`@cloudflare/workers-oauth-provider`): Claude registers a client dynamically, sends the person to `/oauth/authorize`, and the consent page asks for that deployment's connect phrase before granting `coach:read` and `patch:propose`. Grants, refresh tokens, and registered clients live in that environment's `OAUTH_KV` namespace, so nothing OAuth-shaped is shared between people.

`FLOW_COACH_CONNECT_SECRET` is the consent page's whole authentication: at least 32 fresh random characters (`openssl rand -hex 32`), never reused from another secret or person, handed only to the one person allowed to connect to that mailbox. The page fails closed (503) while it is unset or too short.

To connect a person's Claude:

1. In Claude (Settings, Connectors, Add custom connector) add the person-specific URL `https://<their-host>/mcp`. Claude discovers the OAuth endpoints itself; leave any manual auth fields empty.
2. Claude opens the consent page; enter that deployment's connect phrase and approve.
3. Confirm the six tools appear and a read works before any real data is synced.

To disconnect: remove the connector in Claude, then rotate the connect phrase. To force-revoke server-side without the client's cooperation, delete that environment's grants in `OAUTH_KV` (`npx wrangler kv key list --binding OAUTH_KV --env <env>` and delete the listed grant/token keys), then rotate the connect phrase.

### After a contract deploy: refresh the connector

Redeploying the Worker does not touch Claude's cached `tools/list`. Anthropic documents no cache duration and no automatic refetch, so assume a connected client keeps composing against the tool schemas it fetched when the connector was added. That failure is silent and points the wrong way: after the schema 3 deploy, a connected coach reported the patch tool "still advertises schema 2 only", worked around operations that were in fact live, and nothing on either side disagreed out loud (#83).

The server cannot push a correction. `notifications/tools/list_changed` requires a delivery channel — an SSE stream or a session — and this Worker deliberately has neither, so the capability is not advertised (see the `initialize` handler in `src/mcp.ts`).

So the step is manual. After any deploy that changes a tool's input schema, description, or the operation contract:

1. In Claude (Settings, Connectors) refresh the affected person's connector — remove it and add it back if no lighter refresh is offered. Re-approval uses the same connect phrase; grants in `OAUTH_KV` are unaffected.
2. Check it took: ask the coach to list the operation kinds and schema versions visible in its patch tool's input schema, and compare against `capabilities.operationKinds` and `capabilities.patchSchemaVersions` from `get_flow_coach_context`. One message, and it would have caught the incident above.

The coach-context payload also carries a fresh-per-call `advisory` telling a coach to trust the capabilities block over a cached schema and to ask for a refresh, so a stale client that reads a context at least learns it is stale. It does not remove the manual step; it bounds the damage until someone performs it.

## Private ChatGPT GPT (Actions, #49)

ChatGPT uses the existing `/actions/*` edge rather than the MCP connector. The
current importable OpenAPI schema, private-GPT instructions and proof checklist
are in [`chatgpt`](chatgpt). This route needs no ChatGPT developer mode.

Configure one private GPT per Flow mailbox:

1. Follow [`chatgpt/SETUP.md`](chatgpt/SETUP.md), replacing the schema's host
   placeholder with that person's Worker hostname.
2. In the GPT Action authentication settings, choose API key with Bearer
   authentication and enter only that deployment's `FLOW_COACH_ACTIONS_SECRET`.
   [OpenAI says Action API keys are encrypted at rest](https://developers.openai.com/api/docs/actions/authentication),
   but the value remains a live mailbox credential and stays out of source,
   prompts, issues, and logs.
3. Keep the GPT private. Do not reuse its schema, secret, or conversation for
   the other mailbox.
4. Test all six Actions in the editor, then prove one read and one pending-draft
   round trip on web and iPhone. Until that evidence is recorded on #49, the
   ChatGPT route is prepared but not proved.

The schema uses the standard `Authorization: Bearer` header because
[ChatGPT Actions do not support arbitrary custom request headers](https://developers.openai.com/api/docs/actions/production).
Patch validation is marked non-consequential. Pending-patch creation is marked
`x-openai-isConsequential: true`, which makes ChatGPT ask on every write; there
is no always-allow bypass for that action. This prompt does not apply the
patch. Flow still previews, revalidates, and obtains the only confirmation
that can change a routine.

### After a contract deploy: re-import the Action schema

A deployed Worker cannot update a schema already copied into a private GPT.
After a change to Action inputs, operation kinds, schema versions, or
descriptions:

1. Run `npm run check:chatgpt-actions`.
2. Import the current [`chatgpt/openapi.json`](chatgpt/openapi.json) into every
   affected private GPT and save it.
3. Start a fresh conversation and compare what the GPT can compose with
   `capabilities.patchSchemaVersions` and `capabilities.operationKinds` from
   `get_flow_coach_context`.
4. If the fresh `advisory` reports a mismatch, stop before writing and refresh
   the GPT Action again.

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

Before real data, prove isolation with fixture snapshots. `npm run smoke:isolation` does the whole check and cleans up after itself:

```bash
export FLOW_COACH_PRIMARY_ACTIONS_SECRET=... FLOW_COACH_PRIMARY_DEVICE_SECRET=...
export FLOW_COACH_PARTNER_ACTIONS_SECRET=... FLOW_COACH_PARTNER_DEVICE_SECRET=...
npm run smoke:isolation -- https://<primary-host> https://<partner-host>
```

It refuses to run against one hostname or with any credential reused, then proves: both deployments are up and refuse anonymous and tokenless calls; every credential is rejected by the other deployment and by the other edge; each Actions endpoint reads only its own fixture and cannot resolve the other's `contextId` even when given it; a proposal is visible and acknowledgeable only in the mailbox that created it; retries are idempotent; and deleting one snapshot, then all data, in one environment leaves the other intact.

The same script can be rehearsed locally before deploying, which is worth doing after any change to the auth boundary. Give each local instance its own secrets and storage:

```bash
# .dev.vars.primary and .dev.vars.partner hold distinct secrets; both are gitignored.
npx wrangler dev --env primary --port 8787 --persist-to .wrangler/state-primary
npx wrangler dev --env partner --port 8788 --persist-to .wrangler/state-partner
npm run smoke:isolation -- http://127.0.0.1:8787 http://127.0.0.1:8788
```

After the deployed run, rotate the temporary credentials before pairing either phone.

## Rotation

Each environment exposes one active secret per edge. Rotate one boundary in one environment at a time: create the replacement value, update its only client, write the corresponding environment-specific Worker secret, deploy, and immediately verify both an allowed request and a rejected old credential. Rotate the other boundary separately. A dual-secret overlap can be added before production if zero-downtime rotation becomes important; do not reuse a secret across edges or people.

The MCP edge rotates differently because the connect phrase is not a bearer credential: rotating `FLOW_COACH_CONNECT_SECRET` stops new authorisations but leaves existing grants and refresh tokens valid. To rotate a person's MCP access fully, rotate the phrase, delete the grant and token keys in that environment's `OAUTH_KV`, and re-approve the connector once with the new phrase. Access tokens expire after an hour on their own; refresh tokens are what the KV deletion revokes.

## Data deletion and teardown

Delete one snapshot with `DELETE /device/snapshots/{contextId}`. This also removes remote proposals derived from it. Delete all data for one mailbox with that environment's authenticated `DELETE /device/data` before dismantling its Worker. A remote delete cannot retract a patch already saved in Flow's local inbox and must not affect the other environment.

For full teardown:

1. Call `DELETE /device/data` and verify it succeeds.
2. Remove the coach connector configuration in Claude and any private GPT Action using this mailbox.
3. Delete that environment's `OAUTH_KV` namespace so every grant, refresh token, and registered client dies with it.
4. Delete the environment's Worker secrets with Wrangler.
5. Delete that environment's Worker only after its mailbox is empty.
6. Confirm in the Cloudflare dashboard that the Worker, Durable Object namespace/data, KV namespace, routes, custom domain, logs, and secrets are gone.

Do not treat deleting only the Worker script as evidence that Durable Object data was removed.

## Operational boundary

The Worker logs no coach payloads or credentials. Cloudflare invocation metadata and control-plane residency are separate from the Durable Object's EU storage jurisdiction; do not make a broader residency claim without reviewing the account configuration. Production monitoring should use status counts, durations, and opaque IDs only.
