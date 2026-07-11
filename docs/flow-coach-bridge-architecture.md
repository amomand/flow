# ADR: Flow Coach bridge

- **Status:** Provisional; the human gates below remain open
- **Decision date:** 10 July 2026
- **Issues:** [#37](https://github.com/amomand/flow/issues/37), handing off to [#38](https://github.com/amomand/flow/issues/38) and [#39](https://github.com/amomand/flow/issues/39)

## Context

Flow already owns the safety-critical half of the coach loop: a whitelisted `FlowCoachContext`, typed `FlowRoutinePatch` operations, live validation and clean rebase, an explicit preview/apply decision, a durable inbox, and edit history with rollback. The bridge must expose that contract to ChatGPT without becoming a fitness backend or another routine store.

The MCP prototype in #36 proved the shared tool contract. The REST/OpenAPI spike for #46 proves a second adapter over the same domain operations, but its required private-GPT test on desktop and iOS is still a human gate. This decision therefore does not claim that the phone route has passed.

Flow itself remains one person per app installation. `RoutineStore`, the coach inbox, and edit history live in that installation's app sandbox, so two people using Flow on separate phones do not need an app-level account system. The remote bridge is different: its snapshots, proposals, deletion authority, and credentials must never be shared between people. A ChatGPT conversation boundary alone is not an authorization boundary.

## Decision

Provisionally use one managed Cloudflare Worker deployment per person, each with one single-person, SQLite-backed Durable Object restricted to the EU jurisdiction. The Worker is a stateless HTTPS edge; the Durable Object is the only durable remote store and supplies serialized lifecycle updates, alarms, and expiry. No one runs a VM, daemon, or permanent tunnel.

For the first household deployment, use the checked-in `primary` and `partner` Wrangler environments. Cloudflare deploys these as separate Worker services with separate Durable Object storage. Each environment has its own trusted `FLOW_COACH_MAILBOX_ID`, Actions secret, device secret, hostname, and private GPT Action configuration. Mailbox selection comes only from deployment configuration or, in a future shared router, authenticated identity. It never comes from a person name, query parameter, header, or tool argument supplied by the model.

This is deliberately not a general multi-tenant account platform. If Flow later serves more households, a routing Worker may resolve a credential or OAuth subject to a mailbox ID and then select the matching Durable Object. The mailbox schema and Flow contracts can remain unchanged.

Ship the REST/OpenAPI Actions route first if #46 succeeds. MCP is a thin compatibility adapter over the same domain service and stored records; it may follow rather than block the Actions deployment. Provider-specific authentication and transport stay at the adapters. `FlowCoachContext`, `FlowRoutinePatch`, snapshot identities, and pending-patch state do not fork by provider.

The authority boundary is unchanged, and is repeated independently per person:

```text
Person A's Flow -- device credential A --> Worker A / mailbox A
       ^                                      ^
       |                                      |
       +-- review/apply patch                 +-- Actions credential A -- dedicated private GPT A

Person B's Flow -- device credential B --> Worker B / mailbox B
       ^                                      ^
       |                                      |
       +-- review/apply patch                 +-- Actions credential B -- dedicated private GPT B
```

The person operating a coach GPT may differ from the person using the paired Flow installation. That supports one person designing a weekly routine for another without giving the coach authority to apply it: the proposal still lands only in the paired person's Flow inbox for explicit review. Use a separately named GPT and conversation for each person so injuries, preferences, availability, and training history do not bleed across chat context.

The bridge may validate shape, limits, IDs, hash format, and snapshot correlation. It cannot write HealthKit, mutate a routine, mark a local save successful, or auto-apply a proposal. Only Flow revalidates expected values against live routines, cleanly rebases, previews, obtains confirmation, persists through `RoutineStore`, records history, and offers rollback.

## Snapshot and privacy model

`FlowCoachSnapshotEnvelope` wraps, rather than changes, the existing content contract:

```text
contextId: UUID
createdAt: timestamp
expiresAt: timestamp (createdAt + 24 hours)
sharingProfile: categories and schema version explicitly shared by Flow
context: FlowCoachContext
```

`Sync to Coach` is user initiated in v1. There is no background upload. The Durable Object retains the small set of unexpired envelopes, capped at eight, so a continuing chat can propose against the exact `contextId` it read rather than silently moving to the latest snapshot. Creating a patch requires that unexpired `contextId`; expiry returns `410`, while an unknown or superseded identity returns a non-success response that tells the client to read again. A newer upload does not invalidate an older unexpired snapshot.

The default proposed sharing profile is routines plus Flow's derived strength-history summaries. Cardio distance, duration, and elevation form a separate opt-in tier. Heart rate, energy, effort, METs, and any other HealthKit-derived metrics require a further explicit opt-in. Raw routes, route points, HealthKit workout IDs, samples, full HealthKit objects, and per-sample heart rate never enter the envelope. On a consumer ChatGPT plan, real health-derived context must not be shared until `Improve the model for everyone` is disabled.

All durable coach data for one person lives in that deployment's EU-jurisdiction Durable Object. The Worker keeps no payload cache and logs neither snapshots, routine bodies, patch bodies, credentials, nor request headers. Operational logs are limited to opaque IDs, status codes, sizes, timings, and lifecycle transitions. The deployment runbook must document any Cloudflare control-plane metadata that is not covered by the Durable Object location guarantee; the decision promises EU location for stored coach payloads, not an unverified broader residency claim.

Flow exposes `Delete Coach Snapshot`. Deleting one envelope also deletes pending remote patch payloads derived from it. A delete-all/teardown operation is scoped to the authenticated person's deployment and removes every envelope, pending payload, and tombstone in that mailbox before its separately managed secrets are removed. Remote deletion cannot retract a patch already persisted in Flow's local inbox, which the UI must state.

## Patch lifecycle and retries

A pending record carries `patchId`, `contextId`, `routineId`, `baseContentHash`, creation and expiry timestamps, status, adapter-derived provenance, rationale, and the full patch while it is pending. Pending payloads expire after seven days even if their source snapshot has expired; expiry of the snapshot prevents new proposals but does not erase an already-created draft before Flow has had a reasonable chance to pull it.

The lifecycle is `pending -> pulled -> applied | rejected | stale`, with `expired` allowed from any non-terminal remote state. Pulling never implies applying. Flow acknowledges `pulled` only after the patch is durably present in `CoachPatchInbox`, and acknowledges the final state only after the local decision and required local persistence have succeeded.

Proposal creation is idempotent. The Actions and MCP adapters accept an idempotency key; the domain service also computes a deterministic digest from the authenticated principal, adapter, `contextId`, and canonical patch as a retry fallback. An identical retry returns the existing `patchId`. Pulls use a cursor and may repeat records safely; Flow deduplicates by bridge patch ID. Acknowledgements are idempotent monotonic transitions, so a lost response can be retried without replaying a local mutation.

On `applied`, `rejected`, or `stale`, the bridge promptly removes rationale and patch content and retains only an opaque tombstone: patch and context IDs, terminal status, timestamps, and provenance class. Tombstones expire after seven days. Expired records follow the same payload deletion rule. Durable Object alarms enforce snapshot, patch, and tombstone expiry.

## Authentication and rotation

The three credentials are deliberately non-interchangeable:

| Boundary | Credential and scope | Rotation and loss |
|---|---|---|
| Flow device API | A random per-mailbox device credential stored in the paired iOS Keychain; upload/delete snapshots, pull patches, and acknowledge lifecycle only | Pair a replacement, revoke the old credential, and retry outstanding acknowledgements. Reinstall or a lost credential requires re-pairing; no credential is reconstructed from app data. |
| Private GPT Actions | A separate per-mailbox scoped API secret for bounded reads, validation, and proposal creation only | Store it as an environment-specific Worker secret and in that person's private GPT connection, rotate it independently, verify the new secret, then revoke the old one. It cannot call device endpoints or another deployment. |
| MCP adapter | OAuth 2.1 access tokens with explicit `coach:read` and `patch:propose` scopes | The authorization boundary owns expiry, revocation, and refresh. MCP tokens cannot call device endpoints and are unnecessary while MCP is deferred. |

The first deployment keeps the two random credentials as non-readable, environment-specific Worker secrets; it does not put credentials in mailbox records. A future shared router may store only credential verifiers. Provenance is derived from the validated adapter and authenticated principal; model-supplied provider or person text is ignored. Repeated authentication failures are rate-limited without logging supplied values. Lost or suspected-compromised credentials are revoked first, then remote data can be deleted through that deployment's owner runbook before re-pairing.

## Adapter responsibilities and failures

- **Shared domain service:** schema and size bounds, operation-count limits, routine ID and hash-shape checks, exact snapshot correlation, idempotency, lifecycle transitions, retention, and payload deletion.
- **Actions/OpenAPI:** the six bounded operations already proved by the prototype—context summary, routine list, one routine, training summary, patch validation, and pending-patch creation—plus Actions authentication and `chatgpt-actions` provenance.
- **Flow device API:** envelope upload/delete, retry-safe cursor pull, and idempotent acknowledgement. It never reports a local apply result on Flow's behalf.
- **MCP:** the same reads and proposal creation over Streamable HTTP with OAuth 2.1, using the same schemas, fixtures, validation, and records. It adds no MCP-only domain fields and can be deployed later.

Temporary network failure is handled by bounded exponential retry with jitter. Reads and uploads are safe to repeat; creates and acknowledgements use their idempotency rules. An expired or missing snapshot requires a fresh user-initiated sync before another proposal. If a patch is stale against live Flow state, Flow attempts its existing expected-value rebase and otherwise records `stale`; the bridge does not adjudicate the conflict. After reinstall, Flow re-pairs, pulls outstanding records, and deduplicates them against preserved local bridge IDs where available. If local state was also lost, remote records can be reviewed as new inbox entries; none are auto-applied.

## Implementation handoff

[#38](https://github.com/amomand/flow/issues/38) implements the Worker, EU SQLite Durable Object, shared schemas/domain service, Actions API, optional MCP edge, lifecycle alarms, authentication boundaries, contract tests, and deploy/rotation/deletion/teardown runbook. It deploys and verifies two isolated single-person environments before either receives real data. Cross-environment tests must prove that each Actions and device credential is rejected by the other endpoint, neither mailbox can read or delete the other's records, and delete-all affects only its authenticated deployment. Actions must not be exposed anonymously, payloads must not enter logs, and MCP OAuth must not delay the first deployment if the compatibility adapter is deferred.

[#39](https://github.com/amomand/flow/issues/39) implements `FlowCoachSnapshotEnvelope`, sharing controls and explicit sync/delete UI, Keychain pairing and recovery, device API calls, bridge provenance, bridge-ID deduplication into the existing inbox, and durable local-first acknowledgement retries. Pairing must show a human-readable mailbox label and endpoint, enforce one active mailbox per installation, and warn before switching or deleting it; the label is UX, not authorization. It must also make routine, inbox, and edit-history persistence failures visible enough that the bridge is never told `applied` before the routine and local audit state are safely saved.

## Pending human gates

This ADR becomes accepted only after Alex confirms:

1. #46's private GPT can perform the required reads and pending-patch write on both desktop/web and iOS, including the observed confirmation wording, model mode, and cross-device behaviour. A failure revises this ADR before production work.
2. The initial sharing tier. The proposed default is routines plus Flow strength-history summaries; no real context should be uploaded until Alex approves the categories shown by Flow.
3. A Cloudflare account and the EU-jurisdiction Durable Object are acceptable, including any billing, domain, and documented data-location trade-offs.
4. MCP compatibility may follow the Actions-first deployment. If it is required in the first release, #38 must add the OAuth 2.1 edge before deployment rather than changing the domain model.
5. The two-mailbox household model is acceptable: one isolated deployment and private GPT configuration per person, with no shared credential or chat context.
