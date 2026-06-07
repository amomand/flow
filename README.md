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
- Automatic strength progression based on Fail and Easy ratings.
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

Open `Flow.xcodeproj` in Xcode, select an iPhone destination, and run the app.

Command-line build:

```bash
xcodebuild -project Flow.xcodeproj -scheme Flow \
  -destination 'generic/platform=iOS Simulator' build
```

The app uses bundle identifier `com.alexomand.flow`.
