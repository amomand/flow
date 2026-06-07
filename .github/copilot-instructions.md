# Copilot Instructions - Flow

## Build

```bash
xcodebuild -project Flow.xcodeproj -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

No tests, linter, or package manager. Pure SwiftUI with zero dependencies.

## Architecture

**Personal iOS workout app** - side-loaded via Xcode, not for the App Store. Single user, single device. The app combines strength routines, live workout timing, and read-only HealthKit cardio browsing.

The app has three layers:

- **Models** - `Routine -> Section -> ExerciseBlock` hierarchy (persisted as JSON), `WorkoutSession` (in-memory workout state), `SetRating` enum, and SwiftData `Run` records
- **Storage** - `RoutineStore` handles JSON persistence, `SyncCoordinator` mirrors HealthKit workouts, and `AppSettings` stores cardio sync preferences
- **Views** - `RoutineListView` (strength home), `WorkoutFlowView` (workout orchestrator), and the run list/detail HealthKit browser

Key data flow: `Routine.buildSteps()` flattens the routine into a `[WorkoutStep]` array, one entry per individual set. `WorkoutSession` walks through this array, tracking ratings and computing adjustments.

**Automatic difficulty adjustment** runs at workout end: `WorkoutSession.computeAdjustments()` analyses per-exercise ratings (≥50% FAIL → reduce, ≥75% EASY → increase) and `applyAdjustments(to:)` mutates the saved routine. Single-set exercises (warm-ups) are exempt.

**JSON import/export** allows routine creation via any LLM. `RoutineStore.exportRoutineJSON()` and `importRoutineFromJSON()` handle serialisation. Imported routines get fresh UUIDs.

## Conventions

- **TokyoNight terminal aesthetic** — all UI uses the `TN.*` colour constants and `.terminalFont()` modifier. Buttons use `[ BRACKET LABELS ]`, section headers use `// COMMENT STYLE`. Never use system default styling.
- **`@Observable` over `ObservableObject`** — the project uses the Swift 5.9 `@Observable` macro, not the older Combine-based `ObservableObject`/`@Published` pattern.
- **Backward-compatible Codable** — `ExerciseBlock` has a custom `init(from:)` decoder that handles legacy JSON (string reps, single `restSeconds` field). Any model changes must preserve this migration path.
- **Split rest timers** — each exercise has `restBetweenSetsSeconds` (between sets) and `restAfterExerciseSeconds` (after the last set). `WorkoutStep.restSeconds` is a computed property that picks the right one based on `isLastSetOfExercise`.
- **No audio** — the app never touches `AVAudioSession`. Music playback must not be interrupted.
- **Screen stays on** — `isIdleTimerDisabled` is set during workouts only.
- **Xcode project uses explicit file references** - new `.swift` files must be added to `project.pbxproj` manually (PBXFileReference + PBXBuildFile + group children + sources list). Follow the `E1XXXX`/`E0XXXX` ID pattern.
