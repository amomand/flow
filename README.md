# Flow

Flow is a personal iOS exercise app built with SwiftUI. It combines the original IronFlow strength workout timer with the TrailFlow run browser so strength routines and trail runs live in one side-loaded app.

The target is still named `IronFlow` internally to preserve the existing bundle identifier and local routine storage, but the installed app display name is `Flow`.

## What It Does

### Strength

1. Pick a routine from the Strength tab.
2. Follow each set as a focused card showing exercise, set count, reps or timed duration, per-side flag, and notes.
3. Rate rep-based sets as Fail, Good, or Easy. Good is the default.
4. Swipe left to complete a rep-based set and move into rest or the next exercise.
5. Run timed exercises with automatic countdown and auto-advance.
6. Rest between sets or exercises with a countdown, progress ring, skip control, next-exercise label, and vibration at zero.
7. Review an exception-focused workout summary and copy it as Markdown.

### Runs

1. Authorize read-only HealthKit access from the Runs tab.
2. Pick a start date for imported running workouts.
3. Browse runs from the local SwiftData mirror.
4. Open run detail to see route, pace chart, elevation chart, splits, and heart-rate summary.

## Features

- Single app shell with `Strength` and `Runs` tabs.
- Terminal-inspired TokyoNight UI: monospaced type, bracketed controls, and comment-style section headers.
- Phase system for strength routines: Base, Peak, and Deload.
- Phase-driven workout theming, including the light Deload palette.
- Routine editor with sections, exercises, timed work, split rests, notes, per-side flags, and per-phase overrides.
- JSON import/export for strength routines.
- Automatic strength progression based on Fail and Easy ratings.
- Read-only HealthKit running sync into SwiftData.
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

Runs are read from HealthKit and mirrored locally with SwiftData:

```text
Run
|-- id                 # HKWorkout.uuid
|-- startDate
|-- endDate
|-- distanceMetres
|-- durationSeconds
|-- elevationGainMetres
|-- avgHeartRate
`-- maxHeartRate
```

Route locations and derived pace buckets are fetched lazily from HealthKit and cached in memory for the process lifetime.

## Tech

- Pure SwiftUI.
- iOS 26 deployment target.
- Swift Observation with `@Observable`.
- SwiftData for the run mirror.
- HealthKit, MapKit, and Swift Charts for run review.
- Local JSON storage for strength routines.
- Backward-compatible routine decoding for older JSON.

## Project Structure

```text
IronFlow/
|-- IronFlowApp.swift                  # Flow app entry point and tab shell
|-- Flow.entitlements                  # HealthKit entitlement
|-- Theme/
|   |-- TokyoNightColors.swift
|   |-- Theme.swift
|   `-- TerminalStyle.swift
|-- Models/
|   |-- Routine.swift
|   |-- SetRating.swift
|   `-- WorkoutSession.swift
|-- Storage/
|   `-- RoutineStore.swift
|-- Views/
|   |-- RoutineListView.swift
|   |-- Workout/
|   `-- Editor/
`-- Runs/
    |-- Models/
    |-- Storage/
    `-- Views/
```

## Building & Deploying

Open `IronFlow.xcodeproj` in Xcode, select an iPhone destination, and run the app.

Command-line build:

```bash
xcodebuild -project IronFlow.xcodeproj -scheme IronFlow \
  -destination 'generic/platform=iOS Simulator' build
```

The app uses bundle identifier `com.alexomand.IronFlow` so existing IronFlow routine data can survive the display-name change to Flow.
