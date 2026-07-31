# ADR: Flow Coach bridge

- **Status:** Accepted for the provider-neutral MCP architecture; ChatGPT MCP proof [#49](https://github.com/amomand/flow/issues/49) pending on a supported OpenAI surface
- **Decision date:** 10 July 2026; amended 16 July 2026 for the Claude-first pivot and the [#46](https://github.com/amomand/flow/issues/46) spike results; accepted 19 July 2026; amended 31 July 2026 to make MCP explicitly cross-provider
- **Issues:** [#37](https://github.com/amomand/flow/issues/37), handing off to [#38](https://github.com/amomand/flow/issues/38), [#39](https://github.com/amomand/flow/issues/39), [#40](https://github.com/amomand/flow/issues/40), and the secondary-client proof [#49](https://github.com/amomand/flow/issues/49)

## Context

Flow already owns the safety-critical half of the coach loop: a whitelisted `FlowCoachContext`, typed `FlowRoutinePatch` operations, live validation and clean rebase, an explicit preview/apply decision, a durable inbox, and edit history with rollback. The bridge must expose that contract to an LLM chat client without becoming a fitness backend or another routine store.

The first proved client is Claude. Both household users are on Claude, so #46 passed on 16 July 2026 with coach reads and pending patches from desktop and iOS against a deployed `primary` Worker. That proof never made Claude part of the bridge contract: the MCP endpoint, OAuth grant, tools, snapshots and patches are provider-neutral. Issue [#49](https://github.com/amomand/flow/issues/49) now tracks connecting that same endpoint to ChatGPT. The earlier private-GPT Actions package is retained as a fallback smoke surface after hands-on testing showed that a separate GPT without ordinary ChatGPT memory or conversation context is the wrong product experience.

Flow itself remains one person per app installation. `RoutineStore`, the coach inbox, and edit history live in that installation's app sandbox, so two people using Flow on separate phones do not need an app-level account system. The remote bridge is different: its snapshots, proposals, deletion authority, and credentials must never be shared between people. A chat conversation boundary alone is not an authorization boundary.

## Decision

Use one managed Cloudflare Worker deployment per person, each with one single-person, SQLite-backed Durable Object restricted to the EU jurisdiction. The Worker is a stateless HTTPS edge; the Durable Object is the only durable remote store and supplies serialized lifecycle updates, alarms, and expiry. No one runs a VM, daemon, or permanent tunnel. The #46 spike deployment confirmed both hosting assumptions: SQLite-backed Durable Objects run on the Workers free plan (5 GB cap), so the two-deployment household model needs no billing decision, and the EU jurisdiction restriction works deployed.

For the first household deployment, use the checked-in `primary` and `partner` Wrangler environments. Cloudflare deploys these as separate Worker services with separate Durable Object storage. Each environment has its own trusted `FLOW_COACH_MAILBOX_ID`, device secret, smoke-test Actions secret, hostname, and per-person Claude connector configuration. Mailbox selection comes only from deployment configuration or, in a future shared router, authenticated identity. It never comes from a person name, query parameter, header, or tool argument supplied by the model.

This is deliberately not a general multi-tenant account platform. If Flow later serves more households, a routing Worker may resolve a credential or OAuth subject to a mailbox ID and then select the matching Durable Object. The mailbox schema and Flow contracts can remain unchanged.

MCP over Streamable HTTP is the primary LLM-facing edge, with OAuth 2.1 in MVP scope for #38. The REST/OpenAPI Actions facade remains a fallback smoke surface. Provider-specific setup stays outside the domain contract. `FlowCoachContext`, `FlowRoutinePatch`, snapshot identities, and pending-patch state do not fork by provider, and provenance (`mcp`, `chatgpt-actions`) is derived from the authenticated edge, never from model-supplied text. `mcp` deliberately records the trusted transport class rather than trusting a client to identify itself as Claude or ChatGPT.

The authority boundary is unchanged, and is repeated independently per person:

```text
Person A's Flow -- device credential A --> Worker A / mailbox A
       ^                                      ^
       |                                      |
       +-- review/apply patch                 +-- MCP connector A -- chat context A

Person B's Flow -- device credential B --> Worker B / mailbox B
       ^                                      ^
       |                                      |
       +-- review/apply patch                 +-- MCP connector B -- chat context B
```

The person operating a coach conversation may differ from the person using the paired Flow installation. That supports one person designing a weekly routine for another without giving the coach authority to apply it: the proposal still lands only in the paired person's Flow inbox for explicit review. Keep each person's conversational context attached only to their connector and mailbox. A Project, conversation, or model memory can improve context, but none is an authorization boundary.

The bridge may validate shape, limits, IDs, hash format, and snapshot correlation. It cannot write HealthKit, mutate a routine, mark a local save successful, or auto-apply a proposal. Only Flow revalidates expected values against live routines, cleanly rebases, previews, obtains confirmation, persists through `RoutineStore`, records history, and offers rollback.

Client-side tool approval contributes nothing to this model. The #46 spike showed the approval prompt is account-scoped and permanently dismissible: "always allow" granted on desktop silenced the prompt on iOS as well, and subsequent writes ran with no ask on any surface. No design may assume a per-write client confirmation exists. Flow's preview/apply decision carries the entire write-safety burden.

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

The default proposed sharing profile is routines plus Flow's derived strength-history summaries. Cardio distance, duration, and elevation form a separate opt-in tier. Heart rate, energy, effort, METs, and any other HealthKit-derived metrics require a further explicit opt-in. Raw routes, route points, HealthKit workout IDs, samples, full HealthKit objects, and per-sample heart rate never enter the envelope. Real health-derived context must not be shared until the data-training/privacy setting has been checked on each person's Claude account.

All durable coach data for one person lives in that deployment's EU-jurisdiction Durable Object. The Worker keeps no payload cache and logs neither snapshots, routine bodies, patch bodies, credentials, nor request headers. Operational logs are limited to opaque IDs, status codes, sizes, timings, and lifecycle transitions. The deployment runbook must document any Cloudflare control-plane metadata that is not covered by the Durable Object location guarantee; the decision promises EU location for stored coach payloads, not an unverified broader residency claim.

Flow exposes `Delete Coach Snapshot`. Deleting one envelope also deletes pending remote patch payloads derived from it. A delete-all/teardown operation is scoped to the authenticated person's deployment and removes every envelope, pending payload, and tombstone in that mailbox before its separately managed secrets are removed. Remote deletion cannot retract a patch already persisted in Flow's local inbox, which the UI must state.

## Patch lifecycle and retries

A pending record carries `patchId`, `contextId`, `routineId`, `baseContentHash`, creation and expiry timestamps, status, adapter-derived provenance, rationale, and the full patch while it is pending. Pending payloads expire after seven days even if their source snapshot has expired; expiry of the snapshot prevents new proposals but does not erase an already-created draft before Flow has had a reasonable chance to pull it.

The lifecycle is `pending -> pulled -> applied | rejected | stale`, with `expired` allowed from any non-terminal remote state. Pulling never implies applying. Flow acknowledges `pulled` only after the patch is durably present in `CoachPatchInbox`, and acknowledges the final state only after the local decision and required local persistence have succeeded.

Proposal creation is idempotent. The Actions and MCP adapters accept an idempotency key; the domain service also computes a deterministic digest from the authenticated principal, adapter, `contextId`, and canonical patch as a retry fallback. An identical retry returns the existing `patchId`. Pulls use a cursor and may repeat records safely; Flow deduplicates by bridge patch ID. Acknowledgements are idempotent monotonic transitions, so a lost response can be retried without replaying a local mutation.

Competing drafts are expected, not exceptional. The #46 spike produced two valid pending patches for the same exercise from two conversations minutes apart; both were correctly retained because their content differed, and applying either one makes the other's `baseContentHash` stale. The bridge keeps both and lets Flow's inbox adjudicate; the UX requirements for presenting them land in #39.

On `applied`, `rejected`, or `stale`, the bridge promptly removes rationale and patch content and retains only an opaque tombstone: patch and context IDs, terminal status, timestamps, and provenance class. Tombstones expire after seven days. Expired records follow the same payload deletion rule. Durable Object alarms enforce snapshot, patch, and tombstone expiry.

## Capabilities and release ordering

The bridge validates patches; Flow applies them. They ship on separate cycles, so neither can assume the other's version. Flow declares `deviceCapabilities` (the patch schema versions and operation kinds it can apply, derived from the patcher itself) in every snapshot envelope. The bridge stores that with the snapshot and reports the intersection of its own supported set and the device's from `get_flow_coach_context`, then enforces that same intersection when validating. A snapshot from a build too old to declare anything falls back to the conservative schema 2 baseline rather than to everything the bridge happens to accept, so an old phone is never handed a patch it cannot apply.

**Deploy the Worker before shipping a Flow build that sends a new envelope field.** The snapshot envelope schema is strict, so an app that sends a field the deployed Worker does not know about fails every snapshot upload until the Worker catches up. `deviceCapabilities` is the deliberate exception: it is the field expected to grow, so its own schema is non-strict and unknown keys inside it are dropped rather than rejected. That covers later capability additions, not the next new top-level field.

## Authentication and rotation

The three credentials are deliberately non-interchangeable:

| Boundary | Credential and scope | Rotation and loss |
|---|---|---|
| Flow device API | A random per-mailbox device credential stored in the paired iOS Keychain; upload/delete snapshots, pull patches, and acknowledge lifecycle only | Pair a replacement, revoke the old credential, and retry outstanding acknowledgements. Reinstall or a lost credential requires re-pairing; no credential is reconstructed from app data. |
| MCP connector (primary LLM edge) | OAuth 2.1 access tokens with explicit `coach:read` and `patch:propose` scopes, for bounded reads, validation, and proposal creation only | The authorization boundary owns expiry, revocation, and refresh. MCP tokens cannot call device endpoints or another deployment. |
| Actions/private GPT secondary edge | A separate per-mailbox scoped API secret with the same bounded read/validate/propose scope | Store it as an environment-specific Worker secret and in only that person's private GPT, rotate it independently, verify the new secret, then revoke the old one. It cannot call device endpoints or another deployment. |

The #46 spike used a no-auth unguessable URL gated by a minimum-length token in the path. That stays spike-only: it is a bearer credential sitting in connector configuration with no revocation story beyond rotation, and it must never carry real data. The spike also confirmed that the client-side tool prompt contributes nothing to the authorization model, which is why OAuth 2.1 is MVP scope for the MCP edge rather than a follow-up.

The first deployment keeps the random credentials as non-readable, environment-specific Worker secrets; it does not put credentials in mailbox records. A future shared router may store only credential verifiers. Provenance is derived from the validated adapter and authenticated principal; model-supplied provider or person text is ignored. Repeated authentication failures are rate-limited without logging supplied values. Lost or suspected-compromised credentials are revoked first, then remote data can be deleted through that deployment's owner runbook before re-pairing.

## Adapter responsibilities and failures

- **Shared domain service:** schema and size bounds, operation-count limits, routine ID and hash-shape checks, exact snapshot correlation, idempotency, lifecycle transitions, retention, and payload deletion.
- **MCP (primary):** the six bounded operations proved by the prototype and the #46 spike (context summary, routine list, one routine, training summary, patch validation, and pending-patch creation) over stateless Streamable HTTP, with OAuth 2.1 and provider-neutral `mcp` provenance. Each tool advertises its required OAuth scope as well as its safety annotations. Both patch tools publish the full `FlowRoutinePatch` JSON schema so a first-contact client can compose a valid patch without guessing field names; the spike showed an opaque patch argument costs real round-trips.
- **Actions/OpenAPI:** the same six operations behind the Actions secret with `chatgpt-actions` provenance, retained as a fallback smoke surface. The checked-in schema is contract-tested, but a GPT that imported an older copy still needs a manual refresh.
- **Flow device API:** envelope upload/delete, retry-safe cursor pull, and idempotent acknowledgement. It never reports a local apply result on Flow's behalf.

Temporary network failure is handled by bounded exponential retry with jitter. Reads and uploads are safe to repeat; creates and acknowledgements use their idempotency rules. An expired or missing snapshot requires a fresh user-initiated sync before another proposal. If a patch is stale against live Flow state, Flow attempts its existing expected-value rebase and otherwise records `stale`; the bridge does not adjudicate the conflict. After reinstall, Flow re-pairs, pulls outstanding records, and deduplicates them against preserved local bridge IDs where available. If local state was also lost, remote records can be reviewed as new inbox entries; none are auto-applied.

## Implementation handoff

[#38](https://github.com/amomand/flow/issues/38) implements the Worker, EU SQLite Durable Object, shared schemas/domain service, the MCP primary edge with OAuth 2.1 (candidate plumbing: `workers-oauth-provider` and the Agents SDK `McpAgent`), the Actions smoke facade, lifecycle alarms, authentication boundaries, contract tests, and the deploy/rotation/deletion/teardown runbook. Provenance is derived at the authenticated adapter: the Actions edge sets `chatgpt-actions`, while the internal MCP translation sets `mcp`; caller-supplied provenance is discarded before either reaches the store. It deploys and verifies two isolated single-person environments before either receives real data. Cross-environment tests must prove that each connector and device credential is rejected by the other endpoint, neither mailbox can read or delete the other's records, and delete-all affects only its authenticated deployment. Each person's coach client must point at the correct person-specific endpoint, no edge may be exposed anonymously, and payloads must not enter logs.

[#39](https://github.com/amomand/flow/issues/39) implements `FlowCoachSnapshotEnvelope`, sharing controls and explicit sync/delete UI, Keychain pairing and recovery, device API calls, bridge provenance, bridge-ID deduplication into the existing inbox, and durable local-first acknowledgement retries. Pairing must show a human-readable mailbox label and endpoint, enforce one active mailbox per installation, and warn before switching or deleting it; the label is UX, not authorization. It must also make routine, inbox, and edit-history persistence failures visible enough that the bridge is never told `applied` before the routine and local audit state are safely saved. The inbox must present competing drafts against the same routine or exercise together, make it obvious that applying one will stale the other, and make the stale acknowledgement path effortless. Connector behaviour on the partner's Claude plan tier must be verified before that installation pairs.

[#40](https://github.com/amomand/flow/issues/40) runs the household dogfood: one Claude Project per person with its own instructions and connector, the full loop on desktop and iOS, and the second-person loop with the first mailbox untouched. It assumes writes fire without any client-side ask and records plan tier, tool-approval behaviour per surface, cross-device conversation behaviour, and whether anyone is surprised by a silent write.

## Human gates

Closed on 16 July 2026:

1. **Connector proof (was gate 1).** #46's Claude connector performed the required reads and the pending-patch write on both desktop and iOS; results, auth findings, and the tool-approval findings are recorded on #46.
2. **Hosting (was gate 3).** Cloudflare with an EU-jurisdiction Durable Object is confirmed by the spike deployment on Alex's account. The free plan suffices, so there is no billing decision. Data-location trade-offs stand as documented in the privacy section.
3. **Edge ordering (was gate 4).** MCP is the primary, provider-neutral edge with OAuth 2.1. Actions remains a fallback smoke adapter and does not define the ChatGPT product route.

Closed on 19 July 2026, confirmed by Alex alongside the PR #53 review:

4. **The initial sharing tier.** Confirmed as proposed: routines plus Flow strength-history summaries; cardio totals and HealthKit-derived metrics stay separate opt-ins. One operational check remains in #39: no real context is uploaded until Alex approves the concrete categories shown by Flow before the first sync.
5. **The household model.** Confirmed: one isolated deployment and one person-specific connector/chat context per person, with no shared credential or chat context.

All gates for the accepted bridge remain closed. The separate #49 ChatGPT MCP
check is deliberately still open: the server contract can be completed in the
repo and proved in ChatGPT Work on a supported web/desktop surface, but OpenAI's
current product does not expose plugins in ordinary Chat or mobile. That is the
remaining product gate for the intended iPhone experience, not a missing Flow
bridge implementation.
