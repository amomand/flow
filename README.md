# Flow

Flow is a personal iOS exercise app. Personal as in singular: it is built around my routines, my phases, my rest timers, and my belief that a workout app should look like a terminal. It works brilliantly for exactly one person. If you are not that person, welcome; the tour is free, but nothing here was designed with you in mind.

Strength planning, live workout timing, and a read-only HealthKit cardio browser, in one side-loaded app. No backend, no account, no analytics, no third-party packages. When it breaks, the developer finds out at the gym, mid set, which keeps the bug reports honest.

## Strength

Pick a routine and Flow walks you through it one set at a time: a focused card with the exercise, set count, reps or duration, per-side flag, and notes. Rate rep-based sets Fail, Good, or Easy (Good is the default, an optimism set at design time), swipe left to complete, and let timed work count itself down and auto-advance. Rest gets a countdown, a progress ring, a skip control, the next exercise's name, and a vibration at zero.

Afterwards there is an exception-focused summary you can copy as Markdown, and the workout lands in history with ratings, duration, progression decisions, and Apple Watch metrics when HealthKit has them.

Routines have phases (Base, Peak, Deload) and the app themes itself to match, including a light palette for Deload weeks. The editor handles sections, exercises, timed work, split rests, notes, per-side flags, and per-phase overrides. Progression is automatic: Fail and Easy ratings adjust future targets. Routines import and export as JSON.

## Cardio

Authorise read-only HealthKit access, pick a start date, and Flow mirrors your runs and rides into SwiftData. Each workout opens to a route map, pace and elevation charts, splits, and a heart-rate summary. The cardio tabs only appear once runs or rides are found; until then Strength stands alone, which for long stretches of winter is accurate.

Flow never writes to HealthKit. It reads, and it remembers.

## Flow Coach

The one concession to other intelligences. Flow exports a routine context JSON you can hand to an assistant, and accepts back a typed patch that previews as a diff before anything is saved. Patches land in a durable inbox, apply only after review, never auto-apply, and every applied edit is logged and can be rolled back. Paste, file import, and `flow://` deep links all work as transports.

The full contract, with the patch schema, revision hashing, rebase rules, and edit history, lives in [docs/flow-coach.md](docs/flow-coach.md). It is longer than this README, which tells you something about how much the app trusts its coaches.

## Data

Strength routines are JSON in the app documents directory:

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

Completed strength workouts (immutable snapshots, with applied and skipped progression decisions) and the cardio mirror are SwiftData. Route locations are fetched lazily from HealthKit; lightweight row derivations persist on the `Run` model while full routes stay in a bounded in-memory cache for detail views.

## Tech

Pure SwiftUI on an iOS 26 deployment target, Swift Observation with `@Observable`, SwiftData for history and the run mirror, and HealthKit, MapKit, and Swift Charts for cardio review. Routine decoding stays backward compatible with older JSON. The UI is terminal-flavoured TokyoNight: monospaced type, bracketed controls, comment-style section headers. Focused XCTest coverage for progression, routine storage, and route metrics.

## Project structure

```text
Flow/
|-- FlowApp.swift                      # App entry point and tab shell
|-- Flow.entitlements                  # HealthKit entitlement
|-- Info.plist                         # flow:// URL scheme + JSON document type
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
|   |-- FlowRoutineExchange.swift
|   |-- CoachPatchInbox.swift
|   |-- FlowCoachDeepLink.swift
|   `-- CoachEditHistoryStore.swift
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

## Building and deploying

Open `Flow.xcodeproj` in Xcode, select an iPhone destination, and run.

```bash
xcodebuild -project Flow.xcodeproj -scheme Flow \
  -destination 'generic/platform=iOS Simulator' build
```

The bundle identifier is `com.alexomand.flow`. The app is side-loaded, re-signed when Apple insists, and installed on one phone, which is one hundred per cent of the addressable market.
