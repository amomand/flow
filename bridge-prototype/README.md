# Flow Coach bridge prototype

This directory now proves both sides of the proposed Flow Coach bridge:

- [Issue #36](https://github.com/amomand/flow/issues/36), now complete, established the MCP tool contract.
- [Issue #46](https://github.com/amomand/flow/issues/46) adds a small authenticated REST/OpenAPI façade so the same contract can be tested through a private GPT on ChatGPT desktop and iOS.

It is still a fixture-backed prototype. The architecture decision belongs to [#37](https://github.com/amomand/flow/issues/37), deployment to [#38](https://github.com/amomand/flow/issues/38), Flow app integration to [#39](https://github.com/amomand/flow/issues/39), and real dogfooding to [#40](https://github.com/amomand/flow/issues/40).

## The boundary

**The assistant proposes; Flow decides.**

The bridge can return a short-lived coach snapshot and store a pending routine patch. It never mutates a routine, talks directly to HealthKit, or becomes the source of truth. A future Flow build will pull a draft, validate it against live app state, show the difference, and require explicit confirmation before saving anything.

Two adapters sit over the same in-memory stores and validation code:

- `/mcp` — Streamable HTTP MCP, built with the official `@modelcontextprotocol/sdk`.
- `/actions` — ordinary JSON endpoints described by `openapi.yaml`, intended for the private-GPT phone spike.

The REST façade is protected by one static prototype key. That is enough for fixture testing through a private GPT; it is not the final user identity or authorisation design.

## Install and run

Requires Node 22+.

```bash
cd bridge-prototype
npm ci

export FLOW_COACH_ACTIONS_API_KEY='replace-with-a-long-random-value'
npm run start
```

The default endpoints are:

- `http://localhost:3939/mcp`
- `http://localhost:3939/actions`
- `http://localhost:3939/healthz`

`PORT` changes the port. If `FLOW_COACH_ACTIONS_API_KEY` is absent, `/actions` returns `503`; the MCP adapter remains available.

For auto-reload while editing:

```bash
npm run dev
```

## Verification

```bash
npm run typecheck
npm test
npm run smoke
npm run smoke:actions
```

The current local runs cover:

- 11 unit tests for patch validation and retry deduplication.
- 38 MCP smoke assertions through the SDK's real Streamable HTTP client.
- 20 Actions smoke assertions through the real Express server, including missing/wrong credentials, snapshot correlation, routine drill-down, default exclusion of health-derived metrics, validation, storage, and an identical retry returning the same `patchId`.

Both smoke scripts use fixtures only. They do not require a tunnel or a ChatGPT account.

## ChatGPT Actions contract

The schema is in `openapi.yaml`; the private GPT instructions are in `gpt-actions-instructions.md`.

| Operation | Method and path | What it does |
|---|---|---|
| `get_flow_coach_context` | `GET /actions/coach-context` | Returns a lean snapshot, including an opaque `contextId`. |
| `list_flow_routines` | `GET /actions/routines` | Lists the routines and revision hashes in that snapshot. |
| `get_flow_routine` | `GET /actions/routines/{routineId}` | Returns one complete routine before a patch is proposed. |
| `get_flow_training_summary` | `GET /actions/training-summary` | Returns bounded strength/cardio summaries. Health-derived metrics are off by default. |
| `validate_flow_routine_patch` | `POST /actions/patches/validate` | Checks a proposed patch without storing it. |
| `create_pending_flow_routine_patch` | `POST /actions/pending-patches` | Stores a draft for Flow to review; it does not change a routine. |

Every follow-up request includes the `contextId` obtained from `get_flow_coach_context`. If the server has moved to another snapshot, it returns `409` and the GPT must read context again. The identifier is correlation, not authentication.

The server derives `assistantProvider`; the model cannot claim a different provenance. Repeating an identical create request for the same context and adapter returns the existing pending record rather than leaving several indistinguishable drafts behind.

## MCP contract

The six MCP tools remain available:

| Tool | Read only | Destructive | Idempotent |
|---|---:|---:|---:|
| `get_flow_coach_context` | Yes | No | Yes |
| `list_routines` | Yes | No | Yes |
| `get_routine` | Yes | No | Yes |
| `validate_flow_routine_patch` | Yes | No | Yes |
| `create_pending_routine_patch` | No | No | Yes |
| `list_pending_patches` | Yes | No | Yes |

The create tool is a write because it adds a mailbox entry, but it is not destructive. It is now idempotent: a retry returns the existing entry. Server-level MCP instructions state the propose-only boundary, and the create tool repeats the important part in its own description so it is visible at confirmation time.

## Validation split

The bridge rejects obvious garbage early. `src/patch-validation.ts` checks:

- schema version and required fields;
- known operation kinds and their required fields;
- the same value ranges used by Flow's Swift patch validator;
- routine, section, and exercise IDs against the stored snapshot;
- the `c1-...` content-hash shape and equality with the stored routine.

Flow must still check the expected before-values against its live routine, collisions, whether the result would empty a routine, and every preview/apply decision. Passing bridge validation only means “plausible draft.”

The bridge treats Flow's `c1-...` and `s1-...` revision strings as opaque. It relays them and compares them; it does not try to reproduce Flow's Swift canonical encoding and hash implementation.

## Fixture and data handling

`fixtures/coach-context.json` mirrors Flow's schema-2 export and uses the two seed routines from `RoutineStore.swift`. It contains plausible aggregate exercise and cardio summaries, not real user data.

There are no HealthKit routes, samples, workout identifiers, pace buckets, or per-sample heart-rate data in the accepted schema. The Actions training-summary endpoint also removes aggregate Apple Watch/heart-rate fields unless `includeHealthMetrics=true` is requested explicitly.

A real export can be placed at `fixtures/coach-context.local.json`, which is gitignored. Do not use that for the private-GPT spike until the tunnel, key handling, ChatGPT data-control setting, and sharing tier have all been deliberately accepted. The intended phase 5b test needs only the committed fixture.

## Private GPT phone spike

This is the next human gate. The code can prepare the server, schema, instructions, and fixture; creating or editing the private GPT in Alex's ChatGPT account must be done by Alex.

1. Start the server with a temporary, strong `FLOW_COACH_ACTIONS_API_KEY`.
2. Give it a temporary HTTPS URL, for example with a Cloudflare quick tunnel:

   ```bash
   cloudflared tunnel --url http://localhost:3939
   ```

3. Replace `REPLACE_WITH_HTTPS_HOST` in a local copy of `openapi.yaml` with the tunnel hostname. Keep `/actions` in the server URL.
4. In the GPT editor on the web, create or edit a **private** Flow Coach GPT. Add `gpt-actions-instructions.md`, import the edited OpenAPI schema, and configure the schema's `X-Flow-Coach-Key` API-key header with the same temporary value.
5. Use a model/mode that supports Actions. On desktop, ask it to read the fixture routines, discuss a one-set change, validate the patch, and send the draft to Flow.
6. Repeat the read and draft-create path from the ChatGPT iOS app. Confirm that a retried create returns the same `patchId`.
7. Stop the tunnel and server when the check is finished. Record whether read, validation, confirmation, and create worked on each client.

Useful official references:

- [Creating and editing GPTs](https://help.openai.com/en/articles/8554397-creating-a-gpt)
- [GPT Actions introduction](https://platform.openai.com/docs/actions/introduction)
- [GPT Actions authentication](https://platform.openai.com/docs/actions/authentication)

For a separate remote-MCP experiment, expose this server in the same way and register the HTTPS URL ending in `/mcp`. That remains useful compatibility evidence, but issue #46 uses Actions to answer the immediate desktop/iPhone question.

## Prototype-only vs likely to carry forward

| Prototype-only | Likely to carry forward |
|---|---|
| In-memory stores, lost on restart | Separate coach-snapshot and pending-patch concepts |
| Committed fixture data | Flow's schema-2 context and patch field shapes |
| One static Actions API key | Authenticated adapters with server-derived identity/provenance |
| Manual tunnel and localhost process | A remotely reachable HTTPS service |
| One current snapshot | Opaque context correlation and stale-snapshot rejection |
| No Flow pull/apply route | Propose-only mailbox; Flow validates, previews, and applies |
| TypeScript/Express implementation | Shared domain rules behind Actions and MCP adapters |
| Process-local retry index | Idempotent pending-patch creation with durable uniqueness |

The exact cloud shape, retention, per-user identity, audit trail, and whether MCP ships alongside Actions are phase 6 decisions in #37, not conclusions smuggled in by this spike.

## Project structure

```text
bridge-prototype/
|-- openapi.yaml                    # private-GPT Actions schema
|-- gpt-actions-instructions.md     # private-GPT behaviour and trust boundary
|-- fixtures/
|   |-- coach-context.json          # committed synthetic fixture
|   `-- coach-context.local.json    # gitignored optional real export
|-- src/
|   |-- actions-api.ts              # authenticated REST adapter
|   |-- actions-smoke.ts            # end-to-end Actions checks
|   |-- context-store.ts            # snapshot store and bounded projections
|   |-- pending-patch-store.ts      # retry-safe draft mailbox
|   |-- patch-validation.ts         # structured patch validation
|   |-- flow-types.ts               # schemas matching Flow's Codable shapes
|   |-- server.ts                   # shared stores plus Actions and MCP adapters
|   `-- smoke.ts                    # end-to-end MCP checks
`-- test/
    |-- patch-validation.test.ts
    `-- pending-patch-store.test.ts
```
