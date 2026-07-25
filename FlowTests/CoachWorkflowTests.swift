import XCTest
@testable import Flow

final class CoachWorkflowTests: XCTestCase {
    private var createdDirectories: [URL] = []
    private var defaultsSuiteNames: [String] = []

    override func tearDownWithError() throws {
        for url in createdDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        for suite in defaultsSuiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        createdDirectories = []
        defaultsSuiteNames = []
        try super.tearDownWithError()
    }

    func testSnapshotEnvelopeEncodesExplicitDataTiersAndFreshIdentity() throws {
        let routine = Routine(name: "Shared", sections: [])
        let run = Run(
            id: UUID(),
            activity: .running,
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 2_000),
            distanceMetres: 5_000,
            durationSeconds: 1_500,
            elevationGainMetres: 42,
            avgHeartRate: 141,
            maxHeartRate: 168
        )
        let createdAt = Date(timeIntervalSince1970: 3_000)
        let cardioOnly = FlowCoachSharingProfile(dataTiers: [.cardioHistory, .routines, .cardioHistory])

        let first = FlowCoachSnapshotEnvelope.make(
            routines: [routine],
            strengthWorkouts: [],
            cardioWorkouts: [run],
            sharingProfile: cardioOnly,
            createdAt: createdAt
        )
        let second = FlowCoachSnapshotEnvelope.make(
            routines: [routine],
            strengthWorkouts: [],
            cardioWorkouts: [run],
            sharingProfile: cardioOnly,
            createdAt: createdAt
        )

        XCTAssertNotEqual(first.contextId, second.contextId)
        XCTAssertEqual(first.createdAt, createdAt)
        XCTAssertEqual(first.expiresAt.timeIntervalSince(first.createdAt), 24 * 60 * 60, accuracy: 0.001)
        XCTAssertEqual(first.sharingProfile.schemaVersion, 1)
        XCTAssertEqual(first.sharingProfile.dataTiers, [.routines, .cardioHistory])
        XCTAssertEqual(first.context.routines.map(\.id), [routine.id])
        XCTAssertTrue(first.context.recentStrengthSummary.isEmpty)
        XCTAssertEqual(first.context.recentCardioSummary.count, 1)
        XCTAssertNil(first.context.recentCardioSummary[0].averageHeartRate)
        XCTAssertNil(first.context.recentCardioSummary[0].maxHeartRate)

        let json = try XCTUnwrap(first.jsonString())
        XCTAssertTrue(json.contains("\"sharingProfile\""))
        XCTAssertTrue(json.contains("\"dataTiers\""))
        XCTAssertTrue(json.contains("\"routines\""))
        XCTAssertTrue(json.contains("\"cardioHistory\""))
        XCTAssertFalse(json.contains("\"healthMetrics\""))
    }

    func testSnapshotHealthMetricsRequireTheirOwnTier() {
        let run = Run(
            id: UUID(),
            activity: .running,
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 2_000),
            distanceMetres: 5_000,
            durationSeconds: 1_500,
            avgHeartRate: 141,
            maxHeartRate: 168
        )
        let profile = FlowCoachSharingProfile(dataTiers: [.routines, .cardioHistory, .healthMetrics])

        let envelope = FlowCoachSnapshotEnvelope.make(
            routines: [],
            strengthWorkouts: [],
            cardioWorkouts: [run],
            sharingProfile: profile
        )

        XCTAssertEqual(envelope.context.recentCardioSummary[0].averageHeartRate, 141)
        XCTAssertEqual(envelope.context.recentCardioSummary[0].maxHeartRate, 168)
    }

    func testCoachContextOmitsRouteDataAndHealthKitIdsFromCardioSummary() throws {
        let runId = UUID()
        let run = Run(
            id: runId,
            activity: .running,
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 2_000),
            distanceMetres: 5_000,
            durationSeconds: 1_500,
            elevationGainMetres: 42,
            avgHeartRate: 141,
            maxHeartRate: 168,
            paceBuckets: [321.9, 322.1],
            routePoints: [91.123456, -12.654321]
        )

        let context = FlowCoachContext.make(
            routines: [],
            strengthWorkouts: [],
            cardioWorkouts: [run],
            generatedAt: Date(timeIntervalSince1970: 3_000)
        )
        let json = try XCTUnwrap(context.jsonString())

        XCTAssertTrue(json.contains("recentCardioSummary"))
        XCTAssertFalse(json.contains("routePoints"))
        XCTAssertFalse(json.contains("paceBuckets"))
        XCTAssertFalse(json.contains(runId.uuidString))
        XCTAssertFalse(json.contains("91.123456"))
        XCTAssertFalse(json.contains("-12.654321"))
    }

    func testCoachContextOmitsEmptyConstraints() throws {
        let context = FlowCoachContext.make(
            routines: [],
            strengthWorkouts: [],
            cardioWorkouts: [],
            constraintsNotes: "   "
        )
        let json = try XCTUnwrap(context.jsonString())

        XCTAssertFalse(json.contains("\"constraints\""))
    }

    func testPatchPreviewAppliesToCopyBeforeStoreMutation() throws {
        let exerciseId = UUID()
        let routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
                ])
            ]
        )
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: Date(timeIntervalSince1970: 10),
            rationale: "Progress pressing volume.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseReps,
                    exerciseId: exerciseId,
                    expectedIntValue: 8,
                    newIntValue: 10
                )
            ]
        )

        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: [routine])

        XCTAssertEqual(routine.sections[0].exercises[0].reps, 8)
        XCTAssertEqual(preview.originalRoutine.sections[0].exercises[0].reps, 8)
        XCTAssertEqual(preview.updatedRoutine.sections[0].exercises[0].reps, 10)
        XCTAssertEqual(preview.diffs.first?.before, "Press: 8 reps")
    }

    func testTimedDurationPatchDoesNotInflateHiddenReps() throws {
        let exerciseId = UUID()
        let routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Core", exercises: [
                    ExerciseBlock(id: exerciseId, name: "Plank", sets: 2, reps: 30, durationSeconds: 30)
                ])
            ]
        )
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Extend the hold.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceTimedDuration,
                    exerciseId: exerciseId,
                    expectedIntValue: 30,
                    newIntValue: 180
                )
            ]
        )

        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: [routine])

        let exercise = preview.updatedRoutine.sections[0].exercises[0]
        XCTAssertEqual(exercise.durationSeconds, 180)
        XCTAssertEqual(exercise.reps, 30)
    }

    func testRestPatchDiffsUseHumanReadableLabels() throws {
        let exerciseId = UUID()
        let routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(
                        id: exerciseId,
                        name: "Press",
                        sets: 3,
                        reps: 8,
                        restBetweenSetsSeconds: 60,
                        restAfterExerciseSeconds: 90
                    )
                ])
            ]
        )
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Tune rest periods.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceRestBetweenSets,
                    exerciseId: exerciseId,
                    expectedIntValue: 60,
                    newIntValue: 75
                ),
                FlowRoutinePatchOperation(
                    kind: .replaceRestAfterExercise,
                    exerciseId: exerciseId,
                    expectedIntValue: 90,
                    newIntValue: 120
                )
            ]
        )

        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: [routine])

        XCTAssertEqual(preview.diffs[0].title, "Replace rest between sets")
        XCTAssertEqual(preview.diffs[0].before, "Press: rest between sets 60s")
        XCTAssertEqual(preview.diffs[0].after, "Press: rest between sets 75s")
        XCTAssertEqual(preview.diffs[1].title, "Replace rest after exercise")
        XCTAssertEqual(preview.diffs[1].before, "Press: rest after exercise 90s")
        XCTAssertEqual(preview.diffs[1].after, "Press: rest after exercise 120s")
    }

    // MARK: - Phase override consequences (#61)

    /// The case from the first live connector test: Sit-ups at base 2 sets with
    /// a peak override of 3, and a patch raising base to 3. Nothing is
    /// corrupted; peak has simply stopped being a step up on sets.
    func testRaisingBaseToMeetAPeakOverrideIsCalledOutAsFlattened() throws {
        let preview = try previewSetsChange(
            baseSets: 2,
            newSets: 3,
            overrides: [.peak: PhaseOverride(sets: 3, reps: 15), .deload: PhaseOverride(sets: 1, reps: 10)]
        )

        let diff = try XCTUnwrap(preview.diffs.first)
        XCTAssertEqual(diff.after, "Sit-ups: 3 sets", "the base diff itself is unchanged")
        let peak = try XCTUnwrap(diff.phaseConsequences.first { $0.phase == .peak })
        XCTAssertEqual(peak.relation, .matchesBase)
        XCTAssertTrue(peak.flattensProgression)
        XCTAssertEqual(peak.summary, "Peak: 3 sets, the same as base")
        // The routine is still what it was: this changes what is shown.
        XCTAssertEqual(
            preview.updatedRoutine.sections[0].exercises[0].phaseOverrides[.peak],
            PhaseOverride(sets: 3, reps: 15)
        )
        XCTAssertEqual(preview.updatedRoutine.sections[0].exercises[0].sets, 3)
    }

    func testAnOverrideLeftBelowTheNewBaseIsCalledOut() throws {
        let preview = try previewSetsChange(
            baseSets: 2,
            newSets: 4,
            overrides: [.peak: PhaseOverride(sets: 3), .deload: PhaseOverride(sets: 1)]
        )

        let diff = try XCTUnwrap(preview.diffs.first)
        let peak = try XCTUnwrap(diff.phaseConsequences.first { $0.phase == .peak })
        let deload = try XCTUnwrap(diff.phaseConsequences.first { $0.phase == .deload })
        XCTAssertEqual(peak.relation, .belowBase)
        XCTAssertEqual(peak.summary, "Peak: 3 sets, below base at 4")
        XCTAssertEqual(deload.relation, .belowBase)
        // Wording describes the values; it does not say the patch is wrong.
        XCTAssertFalse(peak.summary.lowercased().contains("error"))
        XCTAssertFalse(peak.summary.lowercased().contains("invalid"))
    }

    func testAPhaseWithoutAnOverrideForTheFieldIsNamedRatherThanOmitted() throws {
        let preview = try previewSetsChange(
            baseSets: 2,
            newSets: 3,
            overrides: [.peak: PhaseOverride(sets: 4)]
        )

        let diff = try XCTUnwrap(preview.diffs.first)
        let deload = try XCTUnwrap(diff.phaseConsequences.first { $0.phase == .deload })
        XCTAssertEqual(deload.relation, .inheritsBase)
        XCTAssertEqual(deload.summary, "Deload: follows base at 3 sets")
        let peak = try XCTUnwrap(diff.phaseConsequences.first { $0.phase == .peak })
        XCTAssertEqual(peak.relation, .stepsUpFromBase)
        XCTAssertFalse(peak.flattensProgression, "an override still above base is not a flattened progression")
    }

    func testAnOverrideDivergingOnAnotherFieldOnlyAddsNothing() throws {
        // Peak overrides reps, the patch changes sets: there is nothing for the
        // change to fall out of step with.
        let preview = try previewSetsChange(
            baseSets: 2,
            newSets: 3,
            overrides: [.peak: PhaseOverride(reps: 15)]
        )

        XCTAssertTrue(try XCTUnwrap(preview.diffs.first).phaseConsequences.isEmpty)
    }

    func testAnExerciseWithNoOverridesPreviewsExactlyAsBefore() throws {
        let preview = try previewSetsChange(baseSets: 2, newSets: 3, overrides: [:])

        let diff = try XCTUnwrap(preview.diffs.first)
        XCTAssertTrue(diff.phaseConsequences.isEmpty, "no extra rows and no empty section")
        XCTAssertEqual(diff.before, "Sit-ups: 2 sets")
        XCTAssertEqual(diff.after, "Sit-ups: 3 sets")
    }

    func testRestOperationsGainNoPhaseConsequences() throws {
        let exerciseId = UUID()
        let routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(
                        id: exerciseId,
                        name: "Press",
                        sets: 3,
                        reps: 8,
                        restBetweenSetsSeconds: 60,
                        restAfterExerciseSeconds: 90,
                        phaseOverrides: [.peak: PhaseOverride(sets: 4, reps: 6)]
                    )
                ])
            ]
        )
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Longer rest.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceRestBetweenSets,
                    exerciseId: exerciseId,
                    expectedIntValue: 60,
                    newIntValue: 90
                )
            ]
        )

        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: [routine])

        // PhaseOverride has no rest fields, so there is nothing to report.
        XCTAssertTrue(preview.diffs[0].phaseConsequences.isEmpty)
    }

    func testTimedDurationChangeReportsPhaseConsequences() throws {
        let exerciseId = UUID()
        let routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Core", exercises: [
                    ExerciseBlock(
                        id: exerciseId,
                        name: "Plank",
                        sets: 2,
                        reps: 30,
                        durationSeconds: 30,
                        phaseOverrides: [.peak: PhaseOverride(durationSeconds: 45)]
                    )
                ])
            ]
        )
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Extend the hold.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceTimedDuration,
                    exerciseId: exerciseId,
                    expectedIntValue: 30,
                    newIntValue: 45
                )
            ]
        )

        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: [routine])

        let peak = try XCTUnwrap(preview.diffs[0].phaseConsequences.first { $0.phase == .peak })
        XCTAssertEqual(peak.relation, .matchesBase)
        XCTAssertEqual(peak.summary, "Peak: 45 seconds, the same as base")
    }

    func testDiffRecordsWrittenBeforePhaseConsequencesStillDecode() throws {
        let legacy = """
        {"operationIndex":1,"title":"Replace sets","before":"Sit-ups: 2 sets","after":"Sit-ups: 3 sets"}
        """

        let decoded = try JSONDecoder().decode(FlowRoutinePatchDiff.self, from: Data(legacy.utf8))

        XCTAssertEqual(decoded.title, "Replace sets")
        XCTAssertTrue(decoded.phaseConsequences.isEmpty)
    }

    /// One exercise, one `replaceExerciseSets` operation, with whatever phase
    /// overrides the case under test needs.
    private func previewSetsChange(
        baseSets: Int,
        newSets: Int,
        overrides: [WorkoutPhase: PhaseOverride]
    ) throws -> FlowRoutinePatchPreview {
        let exerciseId = UUID()
        let routine = Routine(
            name: "Wednesday — Upper A",
            sections: [
                Section(name: "Core", exercises: [
                    ExerciseBlock(
                        id: exerciseId,
                        name: "Sit-ups",
                        sets: baseSets,
                        reps: 12,
                        phaseOverrides: overrides
                    )
                ])
            ]
        )
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "More core volume.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseSets,
                    exerciseId: exerciseId,
                    expectedIntValue: baseSets,
                    newIntValue: newSets
                )
            ]
        )
        return try FlowRoutinePatcher.preview(patch: patch, routines: [routine])
    }

    func testStoreAppliesPatchWithRestorableBackup() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let history = CoachEditHistoryStore(
            fileURL: fixture.directory.appendingPathComponent("coach-edit-history.json")
        )
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults, editHistory: history)
        let exerciseId = UUID()
        let routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
                ])
            ]
        )
        store.addRoutine(routine)
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Progress pressing volume.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseReps,
                    exerciseId: exerciseId,
                    expectedIntValue: 8,
                    newIntValue: 10
                )
            ]
        )
        let json = try patchJSON(patch)

        let previewResult = store.previewRoutinePatchJSON(json)
        guard case .success(let preview) = previewResult else {
            return XCTFail("Expected patch preview to succeed")
        }
        XCTAssertEqual(store.routines[0].sections[0].exercises[0].reps, 8)

        let applyResult = store.applyRoutinePatchPreview(preview)
        guard case .success = applyResult else {
            return XCTFail("Expected patch apply to succeed")
        }
        XCTAssertEqual(store.routines[0].sections[0].exercises[0].reps, 10)

        let record = try XCTUnwrap(history.mostRecentRestorable)
        guard case .success(let restored) = store.restoreCoachEdit(record) else {
            return XCTFail("Expected restore to succeed")
        }
        XCTAssertEqual(restored.id, routine.id)
        XCTAssertEqual(store.routines[0].sections[0].exercises[0].reps, 8)
    }

    func testStalePatchWithMatchingExpectedValuesRebasesInPreview() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let exerciseId = UUID()
        let routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
                ])
            ]
        )
        store.addRoutine(routine)
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: "stale",
            exportedAt: nil,
            rationale: "Progress pressing volume.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseReps,
                    exerciseId: exerciseId,
                    expectedIntValue: 8,
                    newIntValue: 10
                )
            ]
        )

        // The hash is stale but the operation's expected before-value still
        // matches the current routine, so Flow rebases instead of rejecting.
        let result = store.previewRoutinePatchJSON(try patchJSON(patch))

        guard case .success(let preview) = result else {
            return XCTFail("Expected stale patch to rebase, got \(result)")
        }
        XCTAssertEqual(preview.rebasedFromHash, "stale")
        XCTAssertEqual(preview.updatedRoutine.sections[0].exercises[0].reps, 10)
        // Preview never mutates the saved routine.
        XCTAssertEqual(store.routines[0].sections[0].exercises[0].reps, 8)
    }

    func testPhaseChangeAloneDoesNotStalePatch() throws {
        let exerciseId = UUID()
        var routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
                ])
            ],
            currentPhase: .base
        )
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Progress pressing volume.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseReps,
                    exerciseId: exerciseId,
                    expectedIntValue: 8,
                    newIntValue: 10
                )
            ]
        )

        // The phase toggles after the patch was created; the content is unchanged.
        routine.currentPhase = .peak

        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: [routine])

        XCTAssertEqual(preview.updatedRoutine.sections[0].exercises[0].reps, 10)
    }

    func testContentChangeUnrelatedToOperationsRebasesCleanly() throws {
        let exerciseId = UUID()
        var routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
                ])
            ]
        )
        let staleHash = FlowRoutineRevision.contentHash(for: routine)
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: staleHash,
            exportedAt: nil,
            rationale: "Progress pressing volume.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseReps,
                    exerciseId: exerciseId,
                    expectedIntValue: 8,
                    newIntValue: 10
                )
            ]
        )

        // Sets changed after the patch was written, so the content hash is
        // stale, but the patched field (reps) still matches its expected
        // before-value: the patch rebases and previews.
        routine.sections[0].exercises[0].sets = 4

        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: [routine])

        XCTAssertEqual(preview.rebasedFromHash, staleHash)
        XCTAssertEqual(preview.updatedRoutine.sections[0].exercises[0].reps, 10)
        XCTAssertEqual(preview.updatedRoutine.sections[0].exercises[0].sets, 4)
    }

    func testContentChangeConflictingWithOperationSurfacesPerOperationConflict() throws {
        let exerciseId = UUID()
        var routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
                ])
            ]
        )
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Progress pressing volume.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseReps,
                    exerciseId: exerciseId,
                    expectedIntValue: 8,
                    newIntValue: 10
                )
            ]
        )

        // The very value the operation edits changed after the patch was
        // written: a genuine conflict, surfaced per operation.
        routine.sections[0].exercises[0].reps = 9

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
            guard case FlowRoutinePatchError.staleConflict(let operationIndex, let reason) = error else {
                return XCTFail("Expected staleConflict, got \(error)")
            }
            XCTAssertEqual(operationIndex, 1)
            XCTAssertTrue(reason.contains("Expected 8"))
            XCTAssertTrue(reason.contains("found 9"))
        }
    }

    func testHashMatchedPatchWithWrongExpectedValueFailsWithoutRebaseTranslation() throws {
        let exerciseId = UUID()
        let routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
                ])
            ]
        )
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Progress pressing volume.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseReps,
                    exerciseId: exerciseId,
                    expectedIntValue: 12,
                    newIntValue: 10
                )
            ]
        )

        // The hash is current, so a wrong expected value means the patch
        // itself is wrong; it must not be dressed up as a stale conflict.
        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
            guard case FlowRoutinePatchError.beforeValueMismatch = error else {
                return XCTFail("Expected beforeValueMismatch, got \(error)")
            }
        }
    }

    func testApplyRevalidatesAgainstRoutineChangedAfterPreview() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let pressId = UUID()
        let rowId = UUID()
        let routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(id: pressId, name: "Press", sets: 3, reps: 8),
                    ExerciseBlock(id: rowId, name: "Row", sets: 3, reps: 10),
                ])
            ]
        )
        store.addRoutine(routine)
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Progress pressing volume.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseReps,
                    exerciseId: pressId,
                    expectedIntValue: 8,
                    newIntValue: 10
                )
            ]
        )

        guard case .success(let preview) = store.previewRoutinePatchJSON(try patchJSON(patch)) else {
            return XCTFail("Expected preview to succeed")
        }

        // The other exercise changes between preview and apply. Apply must
        // revalidate: the patch still rebases cleanly, and the apply result
        // keeps the newer Row edit rather than clobbering it.
        var edited = store.routines[0]
        edited.sections[0].exercises[1].reps = 12
        store.updateRoutine(edited)

        guard case .success(let applied) = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected apply to rebase and succeed")
        }
        XCTAssertEqual(applied.sections[0].exercises[0].reps, 10)
        XCTAssertEqual(applied.sections[0].exercises[1].reps, 12)
    }

    func testApplyFailsWhenRoutineChangeConflictsAfterPreview() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let exerciseId = UUID()
        let routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
                ])
            ]
        )
        store.addRoutine(routine)
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Progress pressing volume.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseReps,
                    exerciseId: exerciseId,
                    expectedIntValue: 8,
                    newIntValue: 10
                )
            ]
        )

        guard case .success(let preview) = store.previewRoutinePatchJSON(try patchJSON(patch)) else {
            return XCTFail("Expected preview to succeed")
        }

        // The patched value itself changes between preview and apply.
        var edited = store.routines[0]
        edited.sections[0].exercises[0].reps = 9
        store.updateRoutine(edited)

        guard case .failure(.staleConflict(let operationIndex, _)) = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected apply to fail with a stale conflict")
        }
        XCTAssertEqual(operationIndex, 1)
        XCTAssertEqual(store.routines[0].sections[0].exercises[0].reps, 9)
    }

    func testApplyAfterPhaseTogglePreservesToggledPhase() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let exerciseId = UUID()
        let routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
                ])
            ],
            currentPhase: .base
        )
        store.addRoutine(routine)
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Progress pressing volume.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseReps,
                    exerciseId: exerciseId,
                    expectedIntValue: 8,
                    newIntValue: 10
                )
            ]
        )
        let previewResult = store.previewRoutinePatchJSON(try patchJSON(patch))
        guard case .success(let preview) = previewResult else {
            return XCTFail("Expected patch preview to succeed")
        }

        // The user toggles the phase between preview and apply. Applying must
        // graft the patched sections without reverting the phase.
        var toggled = store.routines[0]
        toggled.currentPhase = .peak
        store.updateRoutine(toggled)

        let applyResult = store.applyRoutinePatchPreview(preview)
        guard case .success(let applied) = applyResult else {
            return XCTFail("Expected patch apply to succeed")
        }
        XCTAssertEqual(applied.currentPhase, .peak)
        XCTAssertEqual(applied.sections[0].exercises[0].reps, 10)
        XCTAssertEqual(store.routines[0].currentPhase, .peak)
        XCTAssertEqual(store.routines[0].sections[0].exercises[0].reps, 10)
    }

    func testSchemaVersion1PatchIsRejectedWithActionableError() throws {
        let routine = Routine(name: "Coach", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])
        ])
        let v1JSON = """
        {
          "schemaVersion": 1,
          "routineId": "\(routine.id.uuidString)",
          "baseRoutineHash": "0011223344556677",
          "rationale": "Old-style patch.",
          "operations": [{ "kind": "replaceExerciseReps" }]
        }
        """

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(json: v1JSON, routines: [routine])) { error in
            guard case FlowRoutinePatchError.unsupportedSchema(1) = error else {
                return XCTFail("Expected unsupportedSchema(1), got \(error)")
            }
            XCTAssertTrue(
                (error as? FlowRoutinePatchError)?.errorDescription?.contains("schemaVersion 2") == true
            )
        }
    }

    func testPastingWholeRoutineIntoPatchPreviewGivesHelpfulError() throws {
        let routine = Routine(name: "Coach", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])
        ])
        let data = try FlowRoutineExchange.encoder().encode(routine)
        let routineJSON = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(json: routineJSON, routines: [routine])) { error in
            guard case FlowRoutinePatchError.invalidJSON(let message) = error else {
                return XCTFail("Expected invalidJSON, got \(error)")
            }
            XCTAssertTrue(message.contains("full routine export"))
        }
    }

    func testPastingCoachContextIntoPatchPreviewGivesHelpfulError() throws {
        let routine = Routine(name: "Coach", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])
        ])
        let context = FlowCoachContext.make(routines: [routine], strengthWorkouts: [], cardioWorkouts: [])
        let contextJSON = try XCTUnwrap(context.jsonString())

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(json: contextJSON, routines: [routine])) { error in
            guard case FlowRoutinePatchError.invalidJSON(let message) = error else {
                return XCTFail("Expected invalidJSON, got \(error)")
            }
            XCTAssertTrue(message.contains("coach context"))
        }
    }

    func testCoachContextExportsSplitRevisionHashes() throws {
        let routine = Routine(
            name: "Coach",
            sections: [Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])],
            currentPhase: .peak
        )
        let context = FlowCoachContext.make(routines: [routine], strengthWorkouts: [], cardioWorkouts: [])
        let json = try XCTUnwrap(context.jsonString())

        XCTAssertEqual(context.schemaVersion, 2)
        XCTAssertTrue(json.contains("routineContentHashByRoutineId"))
        XCTAssertTrue(json.contains("routineStateHashByRoutineId"))
        XCTAssertEqual(
            context.routineContentHashByRoutineId[routine.id.uuidString],
            FlowRoutineRevision.contentHash(for: routine)
        )
        XCTAssertEqual(
            context.routineStateHashByRoutineId[routine.id.uuidString],
            FlowRoutineRevision.stateHash(for: routine)
        )
    }

    func testPreviewParsesFencedPatchFromChatAssistant() throws {
        let exerciseId = UUID()
        let routine = Routine(
            name: "Coach",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
                ])
            ]
        )
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Progress pressing volume.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseReps,
                    exerciseId: exerciseId,
                    expectedIntValue: 8,
                    newIntValue: 10
                )
            ]
        )
        let wrapped = "Here you go:\n```json\n\(try patchJSON(patch))\n```\nApply when ready."

        let preview = try FlowRoutinePatcher.preview(json: wrapped, routines: [routine])

        XCTAssertEqual(preview.updatedRoutine.sections[0].exercises[0].reps, 10)
    }

    private func patchJSON(_ patch: FlowRoutinePatch) throws -> String {
        let data = try FlowRoutineExchange.encoder().encode(patch)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func makeFixture() throws -> (directory: URL, fileURL: URL, defaults: UserDefaults) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowCoachTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)

        let suiteName = "FlowCoachTests-\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        return (directory, directory.appendingPathComponent("routines.json"), defaults)
    }
}
