# Flow - Design & Architecture

Reference document for future development sessions.

## Product Shape

Flow is one side-loaded iOS app with two exercise surfaces:

- Strength: routine editing and live workout timing.
- Cardio: a read-only HealthKit browser for runs and rides.

The app, Xcode project, scheme, target, product, and bundle identifier use `Flow` or `flow` naming consistently.

## Design Principles

- Terminal aesthetic: TokyoNight palette, SF Mono, `// SECTION HEADERS`, `[ BUTTON LABELS ]`, and comment-coloured secondary text.
- One app, separate domains: strength and cardio share shell/theme primitives, but keep separate models and storage.
- Minimal interaction during workouts: swipe left to advance, tap to rate, avoid mid-set navigation.
- Read-only run sync: Flow reads Apple Health workouts and never writes back.
- No audio session changes: music playback should not be interrupted.
- Screen stays on only during active strength workouts.
- Obsidian-friendly output: strength summaries copy as Markdown.

## App Shell

```text
FlowApp
|-- FlowRootView
    |-- Strength tab -> RoutineListView
    |-- Health Sync sheet from the Strength overflow menu
    `-- Dynamic cardio tabs, shown only when matching workouts exist
        `-- RunListView -> RunDetailView
```

`FlowApp` owns the long-lived stores:

- `RoutineStore` for strength JSON persistence.
- A recoverable SwiftData run cache for HealthKit metadata.
- A separate SwiftData completed-workout history store for strength snapshots.
- `AppSettings.shared` for HealthKit onboarding and start-date filtering.
- `SyncCoordinator` for HealthKit -> SwiftData sync.

## Strength Model

```text
Routine (Codable, stored as JSON in app documents dir)
|-- id: UUID
|-- name: String
|-- currentPhase: WorkoutPhase
`-- sections: [Section]
    |-- id: UUID
    |-- name: String
    `-- exercises: [ExerciseBlock]
        |-- id: UUID
        |-- name: String
        |-- sets: Int
        |-- reps: Int
        |-- durationSeconds: Int?
        |-- restBetweenSetsSeconds: Int
        |-- restAfterExerciseSeconds: Int
        |-- notes: String
        |-- perSide: Bool
        `-- phaseOverrides: [WorkoutPhase: PhaseOverride]
```

`Routine.buildSteps()` resolves phase overrides and flattens the routine into one `WorkoutStep` per set. `WorkoutSession` tracks current step, timers, ratings, summary output, and computed routine adjustments.

## Runs Model

```text
Run (@Model, SwiftData mirror of HKWorkout)
|-- id: UUID
|-- activityRawValue: String
|-- startDate: Date
|-- endDate: Date
|-- distanceMetres: Double
|-- durationSeconds: Double
|-- elevationGainMetres: Double?
|-- avgHeartRate: Double?
|-- maxHeartRate: Double?
|-- paceBuckets: [Double]
`-- routePoints: [Double]
```

`HealthKitService` performs async HealthKit queries. `SyncCoordinator` uses per-activity `HKAnchoredObjectQuery` anchors so running and cycling additions, edits, and deletions reconcile independently. The selected start date is a display filter, not the sync boundary. `RouteCache` lazily loads full route locations for details and keeps them in a bounded LRU; row sparklines and route glyph points are persisted on `Run` after first load.

## Key Behaviours

- Strength default rating is `.good`; swiping without tapping records Good.
- Single-set warmups are exempt from automatic strength progression.
- Peak and Deload ratings are recorded but do not mutate Base progression.
- Progression changes are proposed on the summary screen and require Apply or Skip.
- Completed strength workouts persist immutable snapshots with stable start/end duration.
- Timed per-side holds create explicit left/right timer steps.
- Split rest timers use `restBetweenSetsSeconds` between sets and `restAfterExerciseSeconds` after an exercise.
- Strength timers vibrate at completion and continue to catch up when the app returns active.
- HealthKit onboarding is scoped to the Health Sync sheet; opening Strength should not ask for HealthKit permission.
- Cardio tabs are hidden until matching local workouts exist.
- Cardio lists read SwiftData first and sync in the background.
- Route and chart detail can fail independently of the run list; rows/details log failures and keep rendering available metadata.
- Corrupt existing `routines.json` files are preserved and do not get overwritten by seed migration.

## Shared Theme

The shared `Theme` type covers the strength and cardio surfaces. It includes base strength colours plus run-specific `cyan` and `magenta` slots. Phase-specific themes are still used by the strength workout flow; the app shell and runs area use the default base theme.

## Future Ideas

- Show strength and run activity on one calendar.
- Weekly dashboard: strength sessions completed, run distance, elevation, and fatigue flags.
- Link run days and strength phases to a training block.
- Watch companion for strength rest haptics.
