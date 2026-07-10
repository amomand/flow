# ADR: Flow Coach bridge

- **Status:** Provisional; the human gates below remain open
- **Decision date:** 10 July 2026
- **Issues:** [#37](https://github.com/amomand/flow/issues/37), handing off to [#38](https://github.com/amomand/flow/issues/38) and [#39](https://github.com/amomand/flow/issues/39)

## Context

Flow already owns the safety-critical half of the coach loop: a whitelisted `FlowCoachContext`, typed `FlowRoutinePatch` operations, live validation and clean rebase, an explicit preview/apply decision, a durable inbox, and edit history with rollback. The bridge must expose that contract to ChatGPT without becoming a fitness backend or another routine store.

The MCP prototype in #36 proved the shared tool contract. The REST/OpenAPI spike for #46 proves a second adapter over the same domain operations, but its required private-GPT test on desktop and iOS is still a human gate. This decision therefore does not claim that the phone route has passed.

## Decision

Provisionally use a managed Cloudflare Worker with one single-user, SQLite-backed Durable Object restricted to the EU jurisdiction. The Worker is a stateless HTTPS edge; the Durable Object is the only durable remote store and supplies serialized lifecycle updates, alarms, and expiry. Alex does not run a VM, daemon, or permanent tunnel.

Ship the REST/OpenAPI Actions route first if #46 succeeds. MCP is a thin compatibility adapter over the same domain service and stored records; it may follow rather than block the Actions deployment. Provider-specific authentication and transport stay at the adapters. `FlowCoachContext`, `FlowRoutinePatch`, snapshot identities, and pending-patch state do not fork by provider.

The authority boundary is unchanged:

```text
Flow (source of truth)
  -- user-initiated snapshot --> device API --> shared mailbox
  <-- pending patch ---------- device API <-- shared mailbox
                                             ^
ChatGPT private GPT -- Actions/OpenAPI --------|
MCP clients --------- MCP adapter (optional) --|
```

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

All durable coach data lives in the EU-jurisdiction Durable Object. The Worker keeps no payload cache and logs neither snapshots, routine bodies, patch bodies, credentials, nor request headers. Operational logs are limited to opaque IDs, status codes, sizes, timings, and lifecycle transitions. The deployment runbook must document any Cloudflare control-plane metadata that is not covered by the Durable Object location guarantee; the decision promises EU location for stored coach payloads, not an unverified broader residency claim.

Flow exposes `Delete Coach Snapshot`. Deleting one envelope also deletes pending remote patch payloads derived from it. A delete-all/teardown operation removes every envelope, pending payload, tombstone, verifier, and secret. Remote deletion cannot retract a patch already persisted in Flow's local inbox, which the UI must state.

## Patch lifecycle and retries

A pending record carries `patchId`, `contextId`, `routineId`, `baseContentHash`, creation and expiry timestamps, status, adapter-derived provenance, rationale, and the full patch while it is pending. Pending payloads expire after seven days even if their source snapshot has expired; expiry of the snapshot prevents new proposals but does not erase an already-created draft before Flow has had a reasonable chance to pull it.

The lifecycle is `pending -> pulled -> applied | rejected | stale`, with `expired` allowed from any non-terminal remote state. Pulling never implies applying. Flow acknowledges `pulled` only after the patch is durably present in `CoachPatchInbox`, and acknowledges the final state only after the local decision and required local persistence have succeeded.

Proposal creation is idempotent. The Actions and MCP adapters accept an idempotency key; the domain service also computes a deterministic digest from the authenticated principal, adapter, `contextId`, and canonical patch as a retry fallback. An identical retry returns the existing `patchId`. Pulls use a cursor and may repeat records safely; Flow deduplicates by bridge patch ID. Acknowledgements are idempotent monotonic transitions, so a lost response can be retried without replaying a local mutation.

On `applied`, `rejected`, or `stale`, the bridge promptly removes rationale and patch content and retains only an opaque tombstone: patch and context IDs, terminal status, timestamps, and provenance class. Tombstones expire after seven days. Expired records follow the same payload deletion rule. Durable Object alarms enforce snapshot, patch, and tombstone expiry.

## Authentication and rotation

The three credentials are deliberately non-interchangeable:

| Boundary | Credential and scope | Rotation and loss |
|---|---|---|
| Flow device API | A random device credential stored in the iOS Keychain; upload/delete snapshots, pull patches, and acknowledge lifecycle only | Pair a replacement, revoke the old verifier, and retry outstanding acknowledgements. Reinstall or a lost credential requires re-pairing; no credential is reconstructed from app data. |
| Private GPT Actions | A separate scoped API secret for bounded reads, validation, and proposal creation only | Store it as a Worker secret and in the private GPT connection, rotate it independently, verify the new secret, then revoke the old one. It cannot call device endpoints. |
| MCP adapter | OAuth 2.1 access tokens with explicit `coach:read` and `patch:propose` scopes | The authorization boundary owns expiry, revocation, and refresh. MCP tokens cannot call device endpoints and are unnecessary while MCP is deferred. |

The Durable Object stores only credential verifiers, never recoverable device or Actions secrets. Provenance is derived from the validated adapter and authenticated principal; model-supplied provider text is ignored. Repeated authentication failures are rate-limited without logging supplied values. Lost or suspected-compromised credentials are revoked first, then remote data can be deleted through the deployment's owner runbook before re-pairing.

## Adapter responsibilities and failures

- **Shared domain service:** schema and size bounds, operation-count limits, routine ID and hash-shape checks, exact snapshot correlation, idempotency, lifecycle transitions, retention, and payload deletion.
- **Actions/OpenAPI:** the six bounded operations already proved by the prototype—context summary, routine list, one routine, training summary, patch validation, and pending-patch creation—plus Actions authentication and `chatgpt-actions` provenance.
- **Flow device API:** envelope upload/delete, retry-safe cursor pull, and idempotent acknowledgement. It never reports a local apply result on Flow's behalf.
- **MCP:** the same reads and proposal creation over Streamable HTTP with OAuth 2.1, using the same schemas, fixtures, validation, and records. It adds no MCP-only domain fields and can be deployed later.

Temporary network failure is handled by bounded exponential retry with jitter. Reads and uploads are safe to repeat; creates and acknowledgements use their idempotency rules. An expired or missing snapshot requires a fresh user-initiated sync before another proposal. If a patch is stale against live Flow state, Flow attempts its existing expected-value rebase and otherwise records `stale`; the bridge does not adjudicate the conflict. After reinstall, Flow re-pairs, pulls outstanding records, and deduplicates them against preserved local bridge IDs where available. If local state was also lost, remote records can be reviewed as new inbox entries; none are auto-applied.

## Implementation handoff

[#38](https://github.com/amomand/flow/issues/38) implements the Worker, EU SQLite Durable Object, shared schemas/domain service, Actions API, optional MCP edge, lifecycle alarms, authentication boundaries, contract tests, and deploy/rotation/deletion/teardown runbook. Actions must not be exposed anonymously, payloads must not enter logs, and MCP OAuth must not delay the first deployment if the compatibility adapter is deferred.

[#39](https://github.com/amomand/flow/issues/39) implements `FlowCoachSnapshotEnvelope`, sharing controls and explicit sync/delete UI, Keychain pairing and recovery, device API calls, bridge provenance, bridge-ID deduplication into the existing inbox, and durable local-first acknowledgement retries. It must also make routine, inbox, and edit-history persistence failures visible enough that the bridge is never told `applied` before the routine and local audit state are safely saved.

## Pending human gates

This ADR becomes accepted only after Alex confirms:

1. #46's private GPT can perform the required reads and pending-patch write on both desktop/web and iOS, including the observed confirmation wording, model mode, and cross-device behaviour. A failure revises this ADR before production work.
2. The initial sharing tier. The proposed default is routines plus Flow strength-history summaries; no real context should be uploaded until Alex approves the categories shown by Flow.
3. A Cloudflare account and the EU-jurisdiction Durable Object are acceptable, including any billing, domain, and documented data-location trade-offs.
4. MCP compatibility may follow the Actions-first deployment. If it is required in the first release, #38 must add the OAuth 2.1 edge before deployment rather than changing the domain model.
