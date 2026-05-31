# Flow - Design & Architecture

Reference document for future development sessions.

## Product Shape

Flow is one side-loaded iOS app with two exercise surfaces:

- Strength: the original IronFlow routine editor and live workout timer.
- Runs: the original TrailFlow read-only HealthKit run browser.

The app display name is `Flow`, but the Xcode project, scheme, target, and bundle identifier remain `IronFlow` / `com.alexomand.IronFlow` for continuity with existing local routine data.

## Design Principles

- Terminal aesthetic: TokyoNight palette, SF Mono, `// SECTION HEADERS`, `[ BUTTON LABELS ]`, and comment-coloured secondary text.
- One app, separate domains: strength and runs share shell/theme primitives, but keep separate models and storage.
- Minimal interaction during workouts: swipe left to advance, tap to rate, avoid mid-set navigation.
- Read-only run sync: Flow reads Apple Health workouts and never writes back.
- No audio session changes: music playback should not be interrupted.
- Screen stays on only during active strength workouts.
- Obsidian-friendly output: strength summaries copy as Markdown.

## App Shell

```text
IronFlowApp
|-- FlowRootView
    |-- Strength tab -> RoutineListView
    `-- Runs tab -> RunsRootView
        |-- FirstLaunchView
        `-- RunListView -> RunDetailView
```

`IronFlowApp` owns the long-lived stores:

- `RoutineStore` for strength JSON persistence.
- `ModelContainer(for: Run.self)` for SwiftData.
- `AppSettings.shared` for run onboarding and start-date filtering.
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
|-- startDate: Date
|-- endDate: Date
|-- distanceMetres: Double
|-- durationSeconds: Double
|-- elevationGainMetres: Double?
|-- avgHeartRate: Double?
`-- maxHeartRate: Double?
```

`HealthKitService` performs async HealthKit queries. `SyncCoordinator` imports running workouts from the selected start date and upserts by `HKWorkout.uuid`. `RouteCache` lazily loads route locations and pace buckets for rows/details.

## Key Behaviours

- Strength default rating is `.good`; swiping without tapping records Good.
- Single-set warmups are exempt from automatic strength progression.
- Split rest timers use `restBetweenSetsSeconds` between sets and `restAfterExerciseSeconds` after an exercise.
- Strength timers vibrate at completion and continue to catch up when the app returns active.
- Runs onboarding is scoped to the Runs tab; opening Strength should not ask for HealthKit permission.
- Runs list reads SwiftData first and syncs in the background.
- Route and chart detail can fail independently of the run list; rows/details log failures and keep rendering available metadata.

## Shared Theme

The shared `Theme` type is the superset of the old IronFlow and TrailFlow themes. It includes base strength colours plus run-specific `cyan` and `magenta` slots. Phase-specific themes are still used by the strength workout flow; the app shell and runs area use the default base theme.

## Future Ideas

- Persist strength workout history, then show strength and run activity on one calendar.
- Weekly dashboard: strength sessions completed, run distance, elevation, and fatigue flags.
- Link run days and strength phases to a training block.
- Watch companion for strength rest haptics.
