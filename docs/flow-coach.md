# Flow Coach

The full contract for routine exchange between Flow and an assistant. The README carries the short version; this is the reference.

Flow Coach is the first manual transport for a broader routine exchange contract. The target direction is that a future ChatGPT app or connector can see Flow routine context and propose routine edits, while Flow remains responsible for validation, preview, confirmation, persistence, and rollback.

The provisional production bridge decision is recorded in [Flow Coach bridge architecture](flow-coach-bridge-architecture.md). It keeps the same contract behind separate Actions, device, and optional MCP adapters. Each Flow installation pairs with one isolated single-person mailbox deployment; multiple people do not share bridge credentials or remote data. Its private-GPT, Cloudflare, and initial-sharing-tier human gates remain open.

The manual transport proves the contract and trust boundary before a live bridge exists. It reuses `RoutineStore` and the existing `routines.json` persistence path when a patch is applied, but it does not reuse whole-routine import because that path duplicates routines with fresh IDs. Coach patches edit an existing routine and therefore need their own validation and preview flow.

## Workflow

1. Open Strength -> Flow Coach.
2. Optionally add short coach notes.
3. Copy the coach context JSON, or share it as a `.json` file, and give it to the assistant.
4. Ask the assistant to return a `FlowRoutinePatch` JSON object.
5. Get the patch into Flow by any transport (below); it lands in the pending-patch inbox and previews as a diff.
6. Apply only after reviewing the before/after list, or reject it.

## Pending-patch inbox

Every received patch lands in a durable local inbox (`coach-inbox.json`) regardless of how it arrived. Pending patches survive sheet dismissal and app relaunch, and each entry shows its live readiness against the current routines: `READY` (previews cleanly), `REBASE` (the routine changed but the patch still applies), `CONFLICT` (the routine changed underneath an operation), or `INVALID` (malformed or mismatched). Applying or rejecting resolves the entry; nothing ever auto-applies. The inbox model is transport-agnostic so the future bridge sync client (phase 8) feeds the same inbox rather than a parallel one.

## Transports

- Paste: copy the assistant's patch JSON and tap `PASTE PATCH`. Code fences and surrounding prose are tolerated.
- File: tap `IMPORT FILE` to pick a `.json` patch from Files, or share/open a JSON file into Flow from another app. Coach context can likewise be exported as a file via `SHARE FILE`.
- Deep link: opening `flow://coach` shows the coach sheet; `flow://coach/patch?json=<percent-encoded patch JSON>` (or `?d=<base64url patch JSON>`, optionally with `&provider=claude`) delivers a patch straight into the inbox and opens the preview. This is the smoothest assistant-chat-to-Flow handoff for a side-loaded personal app, and the file and deep-link paths double as the fallback when an assistant's bridge write tool is unavailable on mobile.

## Coach context and revision hashing

Coach context includes routine structure, current phases, split routine revision hashes, recent strength summaries, and derived cardio summaries. It does not include raw HealthKit routes, route samples, cached route points, per-sample heart-rate data, HealthKit workout IDs, or full HealthKit objects.

Routine revision identity is split in two, so unrelated state changes do not stale a patch:

- `routineContentHashByRoutineId` (`c1-...`) covers the editable structure a patch operates on: the ordered sections and exercises. Patches pin to this hash.
- `routineStateHashByRoutineId` (`s1-...`) covers non-structural state, currently the routine's phase.

Toggling a routine's phase between Base, Peak, and Deload changes only the state hash, so a patch whose edited exercises are unchanged still previews and applies. Editing the routine's content changes the content hash and makes patches built against the old structure stale. A stale patch is not rejected outright: every operation carries its expected before-value, and when all of them still match the current routine Flow rebases the patch, marks the preview as rebased, and lets the user review it. When an operation no longer matches, Flow surfaces the specific conflicting operation and asks for a fresh patch. Apply revalidates against the routines as they are at apply time, so a patch can never bypass validation by racing the preview. Hashes are revision identifiers only, never an auth or integrity mechanism.

## Patch format

Routine patches are typed operations against one routine. They must include `schemaVersion` (currently 3, with 2 still accepted), `routineId`, `baseContentHash` (copied from `routineContentHashByRoutineId` in the coach context), `rationale`, and `operations`. They may include `exportedAt` for traceability.

```json
{
  "schemaVersion": 3,
  "routineId": "ROUTINE-UUID",
  "baseContentHash": "c1-hash-from-coach-context",
  "exportedAt": "2026-07-02T21:30:00Z",
  "rationale": "Why this edit is useful.",
  "operations": [
    {
      "kind": "replaceExerciseReps",
      "exerciseId": "EXERCISE-UUID",
      "expectedIntValue": 8,
      "newIntValue": 10
    }
  ]
}
```

Supported operation kinds are `replaceExerciseReps`, `replaceExerciseSets`, `replaceTimedDuration`, `replaceRestBetweenSets`, `replaceRestAfterExercise`, `updateExerciseNotes`, `addExercise`, `removeExercise`, `moveExercise`, `replacePhaseOverride`, and `renameRoutine`.

An operation belongs to the schema version that introduced it, and a patch may only use operations its declared version knows about. `renameRoutine` arrived in schema 3, so it is rejected inside a patch declaring schema 2. That rule is what lets a version number name one fixed operation set on both sides of the bridge.

`renameRoutine` takes `expectedStringValue` (the routine's current name) and `newStringValue` (1 to 100 characters, stored trimmed), and no `exerciseId`. The routine name sits outside `baseContentHash`, which covers sections only, so a rename cannot be rebased the way a numeric change can: `expectedStringValue` is its entire concurrency guard, and a mismatch is a conflict rather than something to work around. For the same reason, undoing an applied edit checks the name as well as the content hash before it puts an old name back.

### Capabilities

Validation happens in the bridge; applying happens in the Flow build on the phone. They are on separate release cycles, so `get_flow_coach_context` reports a `capabilities` block covering both:

```json
"capabilities": {
  "patchSchemaVersions": [2, 3],
  "operationKinds": ["replaceExerciseReps", "...", "renameRoutine"],
  "deviceReported": true
}
```

What it reports is the intersection of what the bridge validates and what the Flow build that uploaded the snapshot declared it can apply, so a coach session can plan against the real limit rather than discovering it by rejection. Validation enforces the same list, and refuses a patch that uses anything outside it. Flow declares its capabilities in every snapshot envelope, derived from the patcher itself rather than a hand-kept list. When a snapshot comes from a build too old to declare anything, `deviceReported` is false and the conservative schema 2 baseline is reported instead.

Flow rejects malformed, conflicting, mismatched, or semantically invalid patches before anything is saved; they sit in the inbox with an explicit reason and cannot mutate saved routines. A future managed or serverless remote MCP bridge can build on the same coach context and patch contract without making the bridge the routine source of truth.

## Edit history and rollback

Every applied coach patch writes a durable audit entry to `coach-edit-history.json`: when it applied, which routine, the hash it pinned to and the hash it actually applied from (these differ when it was rebased), the resulting hash, the rationale, the operation diffs, provenance (inbox patch id, transport, assistant provider, with a context id slot for bridge-delivered patches), and the routine sections and name as they were before the edit. The history holds the last 20 edits and contains no HealthKit or route data.

The coach sheet's `HISTORY` button lists recent edits, newest first. Any entry still in the applied state can be restored: restore grafts the recorded pre-edit sections, and the pre-edit name where the record carries one, back onto the routine through the normal `RoutineStore` save path, leaves non-structural state such as the current phase alone, and flips the entry to restored. If the routine changed after the edit, restore first refuses with a warning and requires an explicit second tap, so later manual edits are never silently overwritten. Records written before schema 3 carry no name, since no patch could change one. Rollback works across app relaunch; a corrupt or missing history file only costs history (a backup of the corrupt file is kept) and can never touch `routines.json`.

## Shared exchange boundary

Whole-routine import/export and coach patch exchange share one boundary, `FlowRoutineExchange`: the JSON encoding conventions, the sanitiser that tolerates code fences and assistant prose, payload detection (pasting a patch into routine import, or a routine or coach context into patch preview, gets a helpful pointer instead of a decode error), and the split revision hashing in `FlowRoutineRevision`. This is the routine exchange foundation the assistant bridge phases build on. The two paths keep their different product semantics: whole-routine import duplicates with fresh routine/section/exercise IDs and can never overwrite an existing routine, while coach patches target an existing routine and apply only through preview and explicit confirmation. `RoutineStore` remains the only authority for mutating and saving `routines.json`.
