# Flow

Flow is a personal iOS exercise app built with SwiftUI. It brings strength workout planning, live workout timing, and a read-only HealthKit cardio browser into one side-loaded app.

The project, target, scheme, installed app, and bundle identifier use `Flow` or `flow` consistently.

## What It Does

### Strength

1. Pick a routine from the Strength tab.
2. Follow each set as a focused card showing exercise, set count, reps or timed duration, per-side flag, and notes.
3. Rate rep-based sets as Fail, Good, or Easy. Good is the default.
4. Swipe left to complete a rep-based set and move into rest or the next exercise.
5. Run timed exercises with automatic countdown and auto-advance.
6. Rest between sets or exercises with a countdown, progress ring, skip control, next-exercise label, and vibration at zero.
7. Review an exception-focused workout summary and copy it as Markdown.
8. Save completed workout history with ratings, duration, applied/skipped progression decisions, and optional Apple Watch metrics from HealthKit strength workouts.

### Cardio

1. Authorize read-only HealthKit access from Health Sync.
2. Pick a start date for imported running and cycling workouts.
3. Browse runs and rides from the local SwiftData mirror.
4. Open workout detail to see route, pace chart, elevation chart, splits, and heart-rate summary.

## Features

- Single app shell with dynamic cardio tabs: `Strength` stands alone until runs or rides are found.
- Terminal-inspired TokyoNight UI: monospaced type, bracketed controls, and comment-style section headers.
- Phase system for strength routines: Base, Peak, and Deload.
- Phase-driven workout theming, including the light Deload palette.
- Routine editor with sections, exercises, timed work, split rests, notes, per-side flags, and per-phase overrides.
- JSON import/export for strength routines.
- Flow Coach export and patch workflow for ChatGPT-assisted routine edits.
- Automatic strength progression based on Fail and Easy ratings.
- Strength workout history with immutable completed-workout snapshots.
- Read-only HealthKit matching for Apple Watch strength workouts, including active energy, exercise time, heart rate, effort, and METs when available.
- Read-only HealthKit running and cycling sync into SwiftData.
- Route thumbnails, MapKit route detail, Swift Charts pace/elevation views, splits, and HR.
- No backend, account, or third-party package dependencies.

## Data Model

Strength routines are stored as JSON in the app documents directory:

```text
Routine
|-- name
|-- currentPhase
`-- sections
    |-- name
    `-- exercises
        |-- name
        |-- sets
        |-- reps
        |-- durationSeconds
        |-- restBetweenSetsSeconds
        |-- restAfterExerciseSeconds
        |-- notes
        |-- perSide
        `-- phaseOverrides
```

Cardio workouts are read from HealthKit and mirrored locally with SwiftData:

```text
Run
|-- id                 # HKWorkout.uuid
|-- activityRawValue   # running or cycling
|-- startDate
|-- endDate
|-- distanceMetres
|-- durationSeconds
|-- elevationGainMetres
|-- avgHeartRate
|-- maxHeartRate
|-- paceBuckets
`-- routePoints
```

Completed strength workouts are stored separately with SwiftData:

```text
CompletedWorkout
|-- startedAt / endedAt / durationSeconds
|-- routineId / routineName / phase
|-- setResults
|-- proposedAdjustments
|-- appliedAdjustments + decision
`-- optional HealthKit strength metrics
```

Route locations are fetched lazily from HealthKit. Lightweight row derivations are persisted on the `Run` model, while full routes stay in a bounded in-memory cache for detail views.

## Flow Coach Workflow

Flow Coach is the first manual transport for a broader routine exchange contract. The target direction is that a future ChatGPT app or connector can see Flow routine context and propose routine edits, while Flow remains responsible for validation, preview, confirmation, persistence, and rollback.

This first version deliberately uses copy/paste JSON to prove the contract and trust boundary before adding a live bridge. It reuses `RoutineStore` and the existing `routines.json` persistence path when a patch is applied, but it does not reuse whole-routine import because that path duplicates routines with fresh IDs. Coach patches edit an existing routine and therefore need their own validation and preview flow.

1. Open Strength -> Flow Coach.
2. Optionally add short coach notes.
3. Copy the coach context JSON and paste it into ChatGPT.
4. Ask ChatGPT to return a `FlowRoutinePatch` JSON object.
5. Paste the patch into Flow Coach and preview the diff.
6. Apply only after reviewing the before/after list.

Coach context includes routine structure, current phases, split routine revision hashes, recent strength summaries, and derived cardio summaries. It does not include raw HealthKit routes, route samples, cached route points, per-sample heart-rate data, HealthKit workout IDs, or full HealthKit objects.

Routine revision identity is split in two, so unrelated state changes do not stale a patch:

- `routineContentHashByRoutineId` (`c1-...`) covers the editable structure a patch operates on: the ordered sections and exercises. Patches pin to this hash.
- `routineStateHashByRoutineId` (`s1-...`) covers non-structural state, currently the routine's phase.

Toggling a routine's phase between Base, Peak, and Deload changes only the state hash, so a patch whose edited exercises are unchanged still previews and applies. Editing the routine's content changes the content hash and stales any patch built against the old structure. Hashes are revision identifiers only, never an auth or integrity mechanism.

Routine patches are typed operations against one routine. They must include `schemaVersion` (currently 2), `routineId`, `baseContentHash` (copied from `routineContentHashByRoutineId` in the coach context), `rationale`, and `operations`. They may include `exportedAt` for traceability.

```json
{
  "schemaVersion": 2,
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

Supported operation kinds are `replaceExerciseReps`, `replaceExerciseSets`, `replaceTimedDuration`, `replaceRestBetweenSets`, `replaceRestAfterExercise`, `updateExerciseNotes`, `addExercise`, `removeExercise`, `moveExercise`, and `replacePhaseOverride`.

Flow rejects malformed, stale, mismatched, or semantically invalid patches before anything is saved. Applying a patch stores the previous routine state so the Flow Coach sheet can restore it immediately. A future managed or serverless remote MCP bridge can build on the same coach context and patch contract without making the bridge the routine source of truth.

Whole-routine import/export and coach patch exchange share one boundary, `FlowRoutineExchange`: the JSON encoding conventions, the sanitiser that tolerates code fences and assistant prose, payload detection (pasting a patch into routine import, or a routine or coach context into patch preview, gets a helpful pointer instead of a decode error), and the split revision hashing in `FlowRoutineRevision`. This is the routine exchange foundation the assistant bridge phases build on. The two paths keep their different product semantics: whole-routine import duplicates with fresh routine/section/exercise IDs and can never overwrite an existing routine, while coach patches target an existing routine and apply only through preview and explicit confirmation. `RoutineStore` remains the only authority for mutating and saving `routines.json`.

## Tech

- Pure SwiftUI.
- iOS 26 deployment target.
- Swift Observation with `@Observable`.
- SwiftData for the run mirror.
- SwiftData for completed strength workout history.
- HealthKit, MapKit, and Swift Charts for run review.
- Local JSON storage for strength routines.
- Backward-compatible routine decoding for older JSON.
- Focused XCTest coverage for progression, routine storage, and route metrics.

## Project Structure

```text
Flow/
|-- FlowApp.swift                      # App entry point and tab shell
|-- Flow.entitlements                  # HealthKit entitlement
|-- Theme/
|   |-- TokyoNightColors.swift
|   |-- Theme.swift
|   `-- TerminalStyle.swift
|-- Models/
|   |-- Routine.swift
|   |-- SetRating.swift
|   `-- WorkoutSession.swift
|-- Coach/
|   |-- FlowCoachContext.swift
|   |-- FlowRoutinePatch.swift
|   `-- FlowRoutineExchange.swift
|-- Storage/
|   `-- RoutineStore.swift
|-- Views/
|   |-- RoutineListView.swift
|   |-- Coach/
|   |-- Workout/
|   `-- Editor/
`-- Runs/
    |-- Models/
    |-- Storage/
    `-- Views/
```

## Building & Deploying

Open `Flow.xcodeproj` in Xcode, select an iPhone destination, and run the app.

Command-line build:

```bash
xcodebuild -project Flow.xcodeproj -scheme Flow \
  -destination 'generic/platform=iOS Simulator' build
```

The app uses bundle identifier `com.alexomand.flow`.
