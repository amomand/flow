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

Supported operation kinds are `replaceExerciseReps`, `replaceExerciseSets`, `replaceTimedDuration`, `replaceRestBetweenSets`, `replaceRestAfterExercise`, `updateExerciseNotes`, `addExercise`, `removeExercise`, `moveExercise`, `replacePhaseOverride`, `renameRoutine`, `addSection`, and `createRoutine`.

An operation belongs to the schema version that introduced it, and a patch may only use operations its declared version knows about. `renameRoutine`, `addSection` and `createRoutine` arrived in schema 3, so they are rejected inside a patch declaring schema 2. That rule is what lets a version number name one fixed operation set on both sides of the bridge.

### Creating a routine

A patch aims at one of two things, chosen by `target`. The default, `existingRoutine`, is everything above: it edits a routine that is already there and carries `routineId` and `baseContentHash`. The other, `newRoutine`, proposes a routine that does not exist yet:

```json
{
  "schemaVersion": 3,
  "target": "newRoutine",
  "rationale": "The split needs a lower day that does not exist yet.",
  "operations": [{ "kind": "createRoutine", "routine": { "id": "UUID", "name": "Lower A", "currentPhase": "deload", "sections": [ ... ] } }]
}
```

It carries no `routineId` and no `baseContentHash`, because there is nothing to anchor to. Modelling that as a discriminated union rather than making the anchor optional for everybody keeps both branches strict: an anchor on a create is refused, and a missing anchor on an edit still is too.

A `newRoutine` patch holds exactly one operation. A new routine arrives whole rather than as a create followed by a stream of `addExercise` operations, because the preview would then have to render intermediate states of a routine that never existed in any of them, and the person approving it would be reading a history rather than a routine.

The coach generates every id: the routine's, each section's, and each exercise's. That is what makes a create idempotent. Applying the same create twice leaves one routine, because the second attempt finds the routine already there and is reported as already applied rather than as a failure, which is what a retry of a draft that landed actually is. Exercise ids must be fresh across every routine, not just the new one, matching what whole-routine import has always done by reassigning ids on the way in.

"Already applied" means the same routine, not merely the same id. A coach revising its own earlier draft will happily reuse the id it generated, so a draft whose id is already here but whose exercises or name are different is reported as a conflict instead: there is something to look at and decide about, and calling it already applied would lose it. The phase is not part of that comparison, since it is state the user owns once the routine is theirs.

A created routine needs at least one section and at least one exercise, a name of 1 to 100 characters, and the same section and per-section exercise ceilings as any other routine. There is also a ceiling on routines themselves, since a snapshot carries at most 50: passing that would fail the next upload whole and stop the coach seeing anything at all. It lands in the phase the patch names, defaulting to `base`.

Undoing an applied create removes the routine it added, since there are no sections to put back and an empty husk would be a worse answer than either keeping it or removing it. This is the only undo that deletes, so it checks the name as well as the exercises before it does: renaming a routine the coach added is how someone makes it their own, and it should not then vanish on one tap. As with any undo, changing it since requires an explicit second tap to overwrite, and the history screen says remove rather than restore for these entries.

### Operations apply in order

Operations run in array order, and each one sees what the ones before it did. A section added by the first operation is a valid target for an `addExercise` in the second, and an exercise added by one operation can be moved by a later one. Flow has always worked this way, since it applies operations to a mutable copy of the routine; the bridge validates the same way rather than checking every reference against the snapshot as it arrived.

`addSection` takes `section` (a fresh `id` and a `name` of 1 to 200 characters, stored trimmed) and an optional `afterSectionId` to place it after an existing section rather than at the end. Sections arrive empty; fill one with `addExercise` operations later in the same patch. A section cannot anchor on itself, an id already in the routine is refused, and a routine cannot be pushed past 50 sections, which is the most the snapshot format will carry back to the coach.

A patch that would leave a routine with no exercises is refused by both the bridge and the app. A routine that was already empty is not refused, since a patch cannot make it emptier, and a patch that clears a section and refills it in the same operations array is fine.

`afterExerciseId` has to name an exercise in the section being added to or moved into, because Flow inserts at that exercise's position within the section. An exercise cannot be anchored on itself: Flow resolves the anchor before the exercise is in place, so there is nothing there yet to sit after. The same ceiling logic as sections applies to exercises: no section may pass 100, which is the most a snapshot will carry back.

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
