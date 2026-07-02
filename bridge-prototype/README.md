# Flow Coach bridge prototype

Phase 5 prototype for [issue #36](https://github.com/amomand/flow/issues/36): prove the MCP tool contract for the Flow Coach bridge against fixtures and a real MCP client, without committing to final infrastructure. That decision is phase 6 ([#37](https://github.com/amomand/flow/issues/37)); the build is phase 7 ([#38](https://github.com/amomand/flow/issues/38)).

This directory is self-contained. Nothing outside `bridge-prototype/` was created or modified to build it.

## What this is

A TypeScript MCP server, built on the official [`@modelcontextprotocol/sdk`](https://www.npmjs.com/package/@modelcontextprotocol/sdk), that exposes Flow's coach context and routine-patch contract as MCP tools over Streamable HTTP — the transport both Claude custom connectors and ChatGPT developer-mode connectors consume. It is a prototype: in-memory stores, fixture-backed context, no database, no auth, no hosting config.

The trust boundary is unchanged from the rest of the Flow Coach programme: **the assistant proposes, Flow decides.** This bridge is a low-authority mailbox — it stores the latest coach context and pending patches, and exposes them as MCP tools. It never mutates a routine, never talks to HealthKit, and never becomes the source of truth. That boundary is stated in the server's `instructions` field (returned in the MCP `initialize` result) so an assistant sees it once, not per-tool.

## How this prototype was run

**Local only.** The server was started on `localhost` with `npm run start` / `npm run smoke`, and exercised with the MCP SDK's own client over Streamable HTTP on `127.0.0.1`. It was not exposed through a tunnel and not deployed anywhere. See "Reaching this from real clients" below for how Alex should expose it for the phone smoke test, and "Alex's smoke-test checklist" for what that phone smoke test needs to record.

## Install and run

Requires Node 22+.

```bash
cd bridge-prototype
npm install

# Start the server (Streamable HTTP on http://localhost:3939/mcp)
npm run start

# Or with auto-reload while editing
npm run dev
```

Environment variables:

- `PORT` — HTTP port (default `3939`).

## Smoke test

```bash
npm run smoke
```

This starts the server on port 3940, connects with the SDK's own `Client` + `StreamableHTTPClientTransport` (i.e. a real MCP client, not a hand-rolled HTTP call), and exercises every tool: reads, a valid `create_pending_routine_patch` call, a stale-hash rejection, a garbage-shaped-hash rejection, and an unknown-routine rejection. Output is human-readable pass/fail.

### Actual output (this prototype, local run)

```
Flow Coach bridge prototype — smoke test
Starting server on port 3940...
Flow Coach bridge prototype listening on http://localhost:3940/mcp

=== Connect ===
  Connected over Streamable HTTP.
  PASS  Server instructions describe the propose-only trust boundary

=== tools/list — annotations ===
  6 tools advertised:
    - get_flow_coach_context: readOnlyHint=true destructiveHint=false idempotentHint=true
    - list_routines: readOnlyHint=true destructiveHint=false idempotentHint=true
    - get_routine: readOnlyHint=true destructiveHint=false idempotentHint=true
    - validate_flow_routine_patch: readOnlyHint=true destructiveHint=false idempotentHint=true
    - create_pending_routine_patch: readOnlyHint=false destructiveHint=false idempotentHint=false
    - list_pending_patches: readOnlyHint=true destructiveHint=false idempotentHint=true
  PASS  tool "get_flow_coach_context" is advertised
  PASS  tool "list_routines" is advertised
  PASS  tool "get_routine" is advertised
  PASS  tool "validate_flow_routine_patch" is advertised
  PASS  tool "create_pending_routine_patch" is advertised
  PASS  tool "list_pending_patches" is advertised
  PASS  "get_flow_coach_context" has readOnlyHint: true
  PASS  "list_routines" has readOnlyHint: true
  PASS  "get_routine" has readOnlyHint: true
  PASS  "validate_flow_routine_patch" has readOnlyHint: true
  PASS  "list_pending_patches" has readOnlyHint: true
  PASS  create_pending_routine_patch has destructiveHint: false
  PASS  create_pending_routine_patch has idempotentHint: false
  PASS  create_pending_routine_patch description states it only stores a draft

=== get_flow_coach_context ===
  PASS  get_flow_coach_context returns 2 routine summaries
  PASS  get_flow_coach_context returns strength/cardio counts, not full arrays
  Payload size: 1290 bytes
  PASS  get_flow_coach_context payload is lean (< 4KB)

=== list_routines ===
  PASS  list_routines returns 2 routines
  PASS  list_routines includes Wednesday — Upper A

=== get_routine (valid id) ===
  PASS  get_routine returns full routine body with sections

=== get_routine (unknown id) — expect rejection ===
  PASS  get_routine reports isError for unknown routine id

=== validate_flow_routine_patch — valid patch ===
  PASS  validate_flow_routine_patch accepts a well-formed patch

=== validate_flow_routine_patch — stale/garbage hash ===
  PASS  validate_flow_routine_patch rejects a stale content hash
  PASS  stale-hash rejection names baseContentHash

=== validate_flow_routine_patch — garbage-shaped hash ===
  PASS  validate_flow_routine_patch rejects a malformed-shape hash

=== validate_flow_routine_patch — unknown routine ===
  PASS  validate_flow_routine_patch rejects an unknown routineId
  PASS  unknown-routine rejection names routineId

=== create_pending_routine_patch — valid create ===
  PASS  create_pending_routine_patch (valid) does not report isError
  PASS  create_pending_routine_patch (valid) stores a draft with status pending
  Stored patchId: bb984931-db5b-4b70-a0be-f0403469fb15

=== create_pending_routine_patch — stale/garbage hash gets rejected ===
  PASS  create_pending_routine_patch (stale hash) reports isError
  PASS  create_pending_routine_patch (stale hash) does not store a draft

=== create_pending_routine_patch — unknown routine gets rejected ===
  PASS  create_pending_routine_patch (unknown routine) reports isError
  PASS  create_pending_routine_patch (unknown routine) does not store a draft

=== list_pending_patches ===
  PASS  list_pending_patches shows exactly the one successfully created patch

=== Summary ===
  35 passed, 0 failed
```

A raw `curl` `initialize` call against `npm run start` was also used to confirm the `instructions` field appears correctly in the real HTTP response (not just through the SDK client), and that a session id is issued per the Streamable HTTP spec.

## Unit tests

```bash
npm run test
```

Nine `vitest` cases covering `validateFlowRoutinePatch`: acceptance of a well-formed patch, stale-hash rejection, unknown-routine rejection, unsupported schema version, out-of-range reps, over-length notes, unknown operation kind, an operation targeting an exercise id absent from the routine, and a malformed hash shape. The smoke script is the primary artefact for this issue; these tests exist because the validation logic was cheap to isolate and worth locking down.

## Tools

Six tools, named exactly as specified in issue #36:

| Tool | `readOnlyHint` | `destructiveHint` | `idempotentHint` | Purpose |
|---|---|---|---|---|
| `get_flow_coach_context` | `true` | `false` | `true` | Lean routine summaries + hashes, strength/cardio counts and short digests, `generatedAt`. Not full history, not full routine bodies. |
| `list_routines` | `true` | `false` | `true` | id, name, phase, hashes, exercise counts for every stored routine. |
| `get_routine` | `true` | `false` | `true` | Full routine body by id, in Flow's `Routine` JSON shape. |
| `validate_flow_routine_patch` | `true` | `false` | `true` | Dry-run validation of a candidate patch. Never stores anything. |
| `create_pending_routine_patch` | `false` | `false` | `false` | Validates, then stores a pending patch. **Does not modify any routine.** |
| `list_pending_patches` | `true` | `false` | `true` | Lists stored patches with lifecycle fields and status. |

Both Claude and ChatGPT use these `annotations` — not just tool descriptions — to calibrate confirmation-prompt UX; ChatGPT in particular treats any tool without `readOnlyHint: true` as a write action requiring approval. `create_pending_routine_patch` is the one tool without it, by design: each call creates a new mailbox entry (`idempotentHint: false`) but never deletes or overwrites routine data (`destructiveHint: false`).

The server-level `instructions` field (in the MCP `initialize` result — see `BRIDGE_INSTRUCTIONS` in `src/server.ts`) states the propose-only trust boundary once, so an assistant does not need it repeated in every tool description. `create_pending_routine_patch`'s own description additionally states plainly, in its first sentence, that it only stores a draft and does not modify routines — the issue calls this out specifically to reduce scary tool-call confirmation prompts, so it is not left to the shared instructions alone.

## Validation split: what the bridge checks vs what only Flow checks

The issue asks explicitly: should `create_pending_routine_patch` merely store a patch, or also run server-side validation? **Decision: the prototype runs server-side schema/hash-shape validation on create, rejecting obvious garbage early, while Flow remains the sole authority for semantic validation, preview, and apply.**

The bridge (`src/patch-validation.ts`) checks, without throwing (every failure becomes a structured `{ path, message }` problem):

- `schemaVersion` is exactly `2` (Flow's `FlowRoutinePatch.currentSchemaVersion`).
- Required top-level fields are present (`routineId`, `baseContentHash`, `rationale`, non-empty `operations`).
- Every operation's `kind` is one of Flow's ten known kinds.
- Per-kind required fields are present (e.g. `replaceExerciseReps` needs `exerciseId`, `expectedIntValue`, `newIntValue`).
- Per-kind value ranges mirror Flow's exactly: reps 1–100, sets 1–10, duration 1–3600s, rest 0–900s, notes ≤500 chars (see `FlowRoutinePatch.swift`'s `validate`/`validateExercise`/`validatePhaseOverride`).
- `routineId` matches a routine in the stored context.
- `baseContentHash` has the `c1-<16 hex>` shape and matches the stored content hash for that routine.
- Referenced `exerciseId`/`sectionId`/`targetSectionId` exist in the routine.

This is why both `validate_flow_routine_patch` and `create_pending_routine_patch` share one function (`validateFlowRoutinePatch`) — `create` is just `validate` plus a store-on-success step.

What the bridge deliberately does **not** check, because only Flow's live app state can:

- Whether an `expectedIntValue`/`expectedStringValue`/`expectedPhaseOverride` "before" value actually matches the exercise's *current* value at the moment of apply (Flow's optimistic-concurrency check — the bridge's stored context can be stale relative to Flow by the time a patch is pulled).
- Whether applying the patch would leave the routine empty (`wouldEmptyRoutine` in Flow's patcher).
- Whether a duplicate exercise id collision exists against Flow's *live* routine (the bridge only knows the routine as of the last pushed context).
- Any UI-level preview/diff/confirmation — that is Flow's alone.

A patch that passes the bridge's validation is a well-formed, plausible draft. It is still just a draft until Flow previews and the user confirms.

## Hash opacity

Coach context and patches carry `c1-...` (content hash) and `s1-...` (state hash) strings from Flow's `FlowRoutineRevision` (FNV-1a over Flow's own canonical JSON encoding — see `FlowRoutineExchange.swift`). **The bridge treats these as opaque strings relayed from Flow. It never computes a hash itself.** Flow's hashing is defined over Flow's own Swift `Codable` encoding order and `JSONEncoder` configuration; reproducing that algorithm faithfully in TypeScript is possible but pointless — any drift between the two implementations (encoding order, float formatting, optional-field omission) would silently produce mismatched hashes and either falsely stale valid patches or falsely accept stale ones. The bridge only checks *shape* (`^c1-[0-9a-f]{16}$`) and *equality* against whatever hash string arrived with the last pushed context. As the issue states: hashes are revision identifiers only, never an auth or integrity mechanism.

## Fixtures

`fixtures/coach-context.json` is a realistic schema-2 `FlowCoachContext` built from the two seed routines in `Flow/Storage/RoutineStore.swift` ("Wednesday — Upper A" and "Sunday — Upper B"), keeping their real UUIDs and structure so the fixture round-trips against Flow's actual decoder shape. It includes:

- Both routines in full, one left at `base` phase and one set to `peak` (to exercise both phase values).
- Plausible `recentStrengthSummary` entries shaped exactly like `FlowCoachStrengthSummary` (ratings, adjustment decisions, notable failures/easy sets, aggregate Apple Watch metrics).
- Plausible `recentCardioSummary` entries shaped exactly like `FlowCoachCardioSummary` (one run, one more run, one ride).
- A `constraints.notes` string.
- Plausible `c1-`/`s1-` hash values (see "Hash opacity" above — these are illustrative strings, not computed).

**No raw HealthKit data appears anywhere in the fixture or the schema that accepts it**: no route points, no pace buckets, no per-sample heart rate, no HealthKit workout UUIDs. `flowCoachStrengthMetricsSchema` and `flowCoachCardioSummarySchema` in `src/flow-types.ts` only accept the same pre-aggregated fields Flow's own `FlowCoachStrengthMetrics`/`FlowCoachCardioSummary` structs expose (duration, active energy, average/max heart rate, effort score, METs, distance, elevation gain) — there is no field in the schema a HealthKit route or per-sample series could even be attached to.

### Using a real exported context

Drop a real coach-context export from the Flow app at `fixtures/coach-context.local.json` (this path is gitignored) and the server will load it instead of the committed fixture. This is for the phone smoke test below, so Alex can point Claude/ChatGPT at his actual routines rather than the fixture data.

## Reaching this from real clients

Both Claude custom connectors and ChatGPT developer-mode connectors expect an MCP server reachable over HTTPS, registered on the web client first and then available on mobile. For local experiments before committing to the managed/serverless bridge in #37, three tunnel options:

**Cloudflare Tunnel** (no account required for a quick tunnel):

```bash
cloudflared tunnel --url http://localhost:3939
```

**ngrok:**

```bash
ngrok http 3939
```

**OpenAI Secure MCP Tunnel** (OpenAI's own tunnel product, built for exactly this developer-mode-connector use case):

See https://developers.openai.com/api/docs/guides/secure-mcp-tunnels for the current CLI invocation — check that page for the latest command, since this is OpenAI's own product and moves independently of this prototype.

Whichever tunnel is used, the resulting HTTPS URL's `/mcp` path is what gets registered with each client below.

### Claude — custom connector

Reference: https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp

1. On claude.ai, go to Settings → Connectors → Add custom connector.
2. Enter the tunnel HTTPS URL with the `/mcp` path, e.g. `https://<your-tunnel>.trycloudflare.com/mcp`.
3. Save, then enable the connector for a conversation.
4. The connector should then be available in the Claude iOS app under the same account — no separate mobile registration step.

### ChatGPT — developer mode connector

Reference: https://developers.openai.com/apps-sdk/deploy/connect-chatgpt

1. Enable developer mode in ChatGPT settings if not already on.
2. Add a connector pointing at the tunnel HTTPS URL with the `/mcp` path.
3. Enable the connector for a conversation.
4. Confirm it also appears in the ChatGPT iOS app under developer mode connectors.

## Alex's smoke-test checklist

This is the human-involvement gate from issue #36 and the phase 5 plan: register the connector on both web clients, then from **both phones** read context and propose one patch each, and record what happened. The issue calls out specifically that ChatGPT developer-mode connectors have at times shipped with MCP write actions disabled on mobile — this is the cheapest way to find out whether that is still true, ahead of any UX built around the answer.

Fill this in after running the checklist:

| Step | Claude (web) | Claude (iOS) | ChatGPT (web) | ChatGPT (iOS) |
|---|---|---|---|---|
| Connector registered | | | | |
| `get_flow_coach_context` read succeeds | | | | |
| `list_routines` / `get_routine` read succeeds | | | | |
| `create_pending_routine_patch` call succeeds | | | | |
| Confirmation prompt shown before the write call | | | | |
| Confirmation prompt wording / screenshot | | | | |
| Payload size issue (truncation) observed? | | | | |
| Notes | | | | |

Specifically to capture for the write-action row: **does `create_pending_routine_patch` actually run from each phone**, or does the client block/hide it as a write action? If ChatGPT iOS blocks it, that is the signal the issue says should decide whether the #34 deep-link fallback needs building before more bridge UX goes on top of an answer we don't have yet.

## Prototype-only vs carries forward to #37 / #38

| Aspect | Prototype-only | Carries forward |
|---|---|---|
| In-memory `ContextStore` / `PendingPatchStore` (`src/context-store.ts`, `src/pending-patch-store.ts`) | Yes — no persistence, no database, lost on restart | The *shape* of what each store holds (lean projection vs full context; lifecycle-field record) carries forward |
| Fixture data (`fixtures/coach-context.json`) | Yes — illustrative data for two named seed routines | The fixture format (a real schema-2 `FlowCoachContext` export) is what a real bridge should accept from Flow |
| No auth / no session persistence across restarts | Yes | A managed/serverless bridge needs real auth before anything writes real data |
| Local-only run, manual tunnel for phone testing | Yes | The managed/serverless hosting decision is #37; this prototype explicitly avoids assuming a long-running VM, a home Mac daemon, or a manually maintained server as the final architecture |
| Tool names (`get_flow_coach_context`, `list_routines`, `get_routine`, `validate_flow_routine_patch`, `create_pending_routine_patch`, `list_pending_patches`) | No | Carries forward as the contract |
| Tool `annotations` (`readOnlyHint`/`destructiveHint`/`idempotentHint`) | No | Carries forward — this is the confirmation-prompt UX lever for both clients |
| Server-level `instructions` (propose-only trust boundary) | No | Carries forward, likely refined with more operational detail once #37 lands |
| Pending-patch lifecycle fields (`patchId`, `contextId`, `routineId`, `baseContentHash`, `createdAt`, `expiresAt`, `status`, `assistantProvider`, `rationale`) | No | Carries forward as the lifecycle contract; status transitions beyond `pending` (`pulled`, `applied`, `rejected`, `stale`, `expired`) are modelled in the type but nothing in this prototype ever sets them — Flow-side pull/apply logic is out of scope here |
| Validation split (bridge does schema/hash-shape; Flow does semantic/preview/apply) | No | Carries forward as the documented decision — see "Validation split" above |
| Hash opacity (bridge never computes hashes) | No | Carries forward — a real bridge should keep relaying Flow's hash strings verbatim |
| Zod schemas mirroring Flow's Swift `Codable` shapes (`src/flow-types.ts`) | Partially | The *field names and ranges* carry forward; the zod-specific implementation does not survive a language/platform change (e.g. if the bridge ends up on a non-Node runtime) |

## Payload size

`get_flow_coach_context` is deliberately lean — routine summaries with counts and hashes, not full routine bodies; strength/cardio *counts* and short digests, not full summary arrays. The smoke test's fixture payload is ~1.3KB. Both Claude and ChatGPT truncate large tool results, and `list_routines` + `get_routine` already give the assistant a granular drill-down path, so the context tool does not need to carry everything up front. If a future real user's coach context (more routines, more history) makes the lean projection itself large, the digest limits in `context-store.ts` (`recentStrengthDigest`/`recentCardioDigest`, currently the 5 most recent of each) are the place to tighten further.

## Project structure

```text
bridge-prototype/
|-- package.json
|-- tsconfig.json
|-- vitest.config.ts
|-- .gitignore
|-- README.md
|-- fixtures/
|   |-- coach-context.json          # committed fixture, built from RoutineStore.swift's seed routines
|   `-- coach-context.local.json    # gitignored — drop a real Flow export here for phone testing
|-- src/
|   |-- flow-types.ts               # zod schemas mirroring Flow's Swift Codable shapes
|   |-- patch-validation.ts         # structured (non-throwing) FlowRoutinePatch validation
|   |-- context-store.ts            # in-memory coach context store + lean projection
|   |-- pending-patch-store.ts      # in-memory pending-patch mailbox with lifecycle fields
|   |-- server.ts                   # McpServer, all six tools, Streamable HTTP transport
|   `-- smoke.ts                    # end-to-end smoke test against a real MCP client
`-- test/
    `-- patch-validation.test.ts    # vitest unit tests for the validation logic
```
