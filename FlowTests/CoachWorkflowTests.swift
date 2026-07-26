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
        XCTAssertEqual(preview.originalRoutine?.sections[0].exercises[0].reps, 8)
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
        XCTAssertEqual(peak.summary, "Peak: 3 sets, below base at 4 sets")
        XCTAssertEqual(deload.relation, .belowBase)
        // A deload of one set is the ordinary case, so the unit has to agree
        // with the number.
        XCTAssertEqual(deload.summary, "Deload: 1 set, below base at 4 sets")
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
                (error as? FlowRoutinePatchError)?.errorDescription?.contains("schemaVersion 3") == true
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

    // MARK: - Schema 3: renameRoutine

    func testRenameRoutinePreviewsAndAppliesTheNewName() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let routine = Routine(name: "Wednesday — Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press", sets: 3, reps: 8)])
        ])
        store.addRoutine(routine)

        let json = try patchJSON(renamePatch(for: routine, to: "Upper A"))
        guard case .success(let preview) = store.previewRoutinePatchJSON(json) else {
            return XCTFail("Expected rename preview to succeed")
        }
        XCTAssertEqual(preview.diffs.first?.title, "Rename routine")
        XCTAssertEqual(preview.diffs.first?.before, "Wednesday — Upper A")
        XCTAssertEqual(preview.diffs.first?.after, "Upper A")
        XCTAssertEqual(store.routines[0].name, "Wednesday — Upper A")

        guard case .success = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected rename apply to succeed")
        }
        XCTAssertEqual(store.routines[0].name, "Upper A")
        XCTAssertEqual(store.routines[0].sections, routine.sections)
    }

    func testRenameIsUndoneByRestore() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let history = CoachEditHistoryStore(
            fileURL: fixture.directory.appendingPathComponent("coach-edit-history.json")
        )
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults, editHistory: history)
        let routine = Routine(name: "Wednesday — Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press", sets: 3, reps: 8)])
        ])
        store.addRoutine(routine)

        let json = try patchJSON(renamePatch(for: routine, to: "Upper A"))
        guard case .success(let preview) = store.previewRoutinePatchJSON(json),
              case .success = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected rename to apply")
        }
        XCTAssertEqual(store.routines[0].name, "Upper A")

        let record = try XCTUnwrap(history.mostRecentRestorable)
        guard case .success = store.restoreCoachEdit(record) else {
            return XCTFail("Expected restore to succeed")
        }
        XCTAssertEqual(store.routines[0].name, "Wednesday — Upper A")
    }

    /// The content hash covers sections only, so it cannot notice a rename.
    /// Without a name check of its own, undo would silently revert a rename
    /// the user made by hand after the edit.
    func testRestoreRefusesWhenTheRoutineWasRenamedAfterTheEdit() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let history = CoachEditHistoryStore(
            fileURL: fixture.directory.appendingPathComponent("coach-edit-history.json")
        )
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults, editHistory: history)
        let routine = Routine(name: "Wednesday — Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press", sets: 3, reps: 8)])
        ])
        store.addRoutine(routine)

        let json = try patchJSON(renamePatch(for: routine, to: "Upper A"))
        guard case .success(let preview) = store.previewRoutinePatchJSON(json),
              case .success = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected rename to apply")
        }

        var renamedByHand = store.routines[0]
        renamedByHand.name = "Upper A (heavy)"
        store.updateRoutine(renamedByHand)

        let record = try XCTUnwrap(history.mostRecentRestorable)
        guard case .failure(let error) = store.restoreCoachEdit(record) else {
            return XCTFail("Expected restore to refuse a routine renamed since the edit")
        }
        XCTAssertEqual(error, .routineChangedSinceEdit("Upper A (heavy)"))
        XCTAssertEqual(store.routines[0].name, "Upper A (heavy)")

        guard case .success = store.restoreCoachEdit(record, allowingOverwrite: true) else {
            return XCTFail("Expected an explicit overwrite to restore")
        }
        XCTAssertEqual(store.routines[0].name, "Wednesday — Upper A")
    }

    func testRenameRoutineIsRejectedInASchemaTwoPatch() throws {
        let routine = Routine(name: "Upper", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])
        ])
        var patch = renamePatch(for: routine, to: "Upper A")
        patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: patch.routineId,
            baseContentHash: patch.baseContentHash,
            exportedAt: nil,
            rationale: patch.rationale,
            operations: patch.operations
        )

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
            guard case FlowRoutinePatchError.operationNeedsNewerSchema("renameRoutine", 3, 2) = error else {
                return XCTFail("Expected operationNeedsNewerSchema, got \(error)")
            }
        }
    }

    func testRenameRoutineWithAStaleExpectedNameConflicts() throws {
        let routine = Routine(name: "Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])
        ])
        let patch = FlowRoutinePatch(
            schemaVersion: 3,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Rename against a name that has moved on.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .renameRoutine,
                    expectedStringValue: "Wednesday — Upper A",
                    newStringValue: "Upper A2"
                )
            ]
        )

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
            guard case FlowRoutinePatchError.beforeValueMismatch("routine name", "Wednesday — Upper A", "Upper A") = error else {
                return XCTFail("Expected beforeValueMismatch, got \(error)")
            }
        }
    }

    func testRenameRoutineBoundsAndTrimsTheNewName() throws {
        let routine = Routine(name: "Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])
        ])

        for candidate in ["   ", String(repeating: "x", count: 101)] {
            let patch = renamePatch(for: routine, to: candidate)
            XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
                guard case FlowRoutinePatchError.invalidValue("routine name", _) = error else {
                    return XCTFail("Expected invalidValue for \"\(candidate)\", got \(error)")
                }
            }
        }

        let padded = try FlowRoutinePatcher.preview(
            patch: renamePatch(for: routine, to: "  Upper B  "),
            routines: [routine]
        )
        XCTAssertEqual(padded.updatedRoutine.name, "Upper B")
    }

    /// Patches already in flight when this build ships still mean what they
    /// meant, so schema 2 keeps working exactly as it did.
    func testSchemaVersion2PatchStillPreviews() throws {
        let exerciseId = UUID()
        let routine = Routine(name: "Coach", sections: [
            Section(name: "Main", exercises: [
                ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
            ])
        ])
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "A patch written before schema 3 existed.",
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
        XCTAssertEqual(preview.updatedRoutine.sections[0].exercises[0].reps, 10)
    }

    /// The bridge advertises what this build declares, so what it declares has
    /// to be what the patcher actually accepts rather than a hand-kept list.
    func testDeclaredCapabilitiesMatchWhatThePatcherAccepts() throws {
        let capabilities = FlowCoachDeviceCapabilities.current

        XCTAssertEqual(capabilities.patchSchemaVersions, FlowRoutinePatch.supportedSchemaVersions.sorted())
        XCTAssertEqual(
            Set(capabilities.operationKinds),
            Set(FlowRoutinePatchOperation.Kind.allCases.map(\.rawValue))
        )
        XCTAssertTrue(capabilities.operationKinds.contains("renameRoutine"))

        let envelope = FlowCoachSnapshotEnvelope.make(
            routines: [Routine(name: "Shared", sections: [])],
            strengthWorkouts: [],
            cardioWorkouts: []
        )
        let encoded = try XCTUnwrap(envelope.jsonString())
        XCTAssertTrue(encoded.contains("\"deviceCapabilities\""))
        XCTAssertTrue(encoded.contains("renameRoutine"))
    }

    /// Capability advertisement is only worth anything if both sides agree
    /// what a schema version contains, and two hand-kept lists in two
    /// languages drift. `patch-operations.json` is the one contract; the
    /// bridge derives its list from it and this asserts the app against it.
    func testOperationKindsMatchTheSharedBridgeContract() throws {
        struct SharedContract: Decodable {
            let patchSchemaVersions: [Int]
            let operationKindMinimumSchema: [String: Int]
        }
        let contractURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("bridge-worker/src/patch-operations.json")
        let contract = try JSONDecoder().decode(
            SharedContract.self,
            from: try Data(contentsOf: contractURL)
        )

        XCTAssertEqual(
            contract.patchSchemaVersions.sorted(),
            FlowRoutinePatch.supportedSchemaVersions.sorted()
        )
        let patcherKinds = Dictionary(
            uniqueKeysWithValues: FlowRoutinePatchOperation.Kind.allCases.map {
                ($0.rawValue, $0.minimumSchemaVersion)
            }
        )
        XCTAssertEqual(patcherKinds, contract.operationKindMinimumSchema)
    }

    /// Every record carries a `previousName`, so treating its presence as
    /// "this edit owns the name" would make any later manual rename block the
    /// undo of an unrelated numeric edit, and an overwrite would revert the
    /// rename as collateral.
    func testManualRenameDoesNotBlockUndoOfAnEditThatNeverRenamed() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let history = CoachEditHistoryStore(
            fileURL: fixture.directory.appendingPathComponent("coach-edit-history.json")
        )
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults, editHistory: history)
        let exerciseId = UUID()
        let routine = Routine(name: "Upper A", sections: [
            Section(name: "Main", exercises: [
                ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
            ])
        ])
        store.addRoutine(routine)

        let patch = FlowRoutinePatch(
            schemaVersion: 3,
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
        guard case .success(let preview) = store.previewRoutinePatchJSON(try patchJSON(patch)),
              case .success = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected the reps change to apply")
        }

        var renamedByHand = store.routines[0]
        renamedByHand.name = "Upper A (heavy)"
        store.updateRoutine(renamedByHand)

        let record = try XCTUnwrap(history.mostRecentRestorable)
        guard case .success = store.restoreCoachEdit(record) else {
            return XCTFail("Expected undo of a non-rename edit to succeed")
        }
        XCTAssertEqual(store.routines[0].sections[0].exercises[0].reps, 8)
        XCTAssertEqual(store.routines[0].name, "Upper A (heavy)")
    }

    /// An empty routine cannot be emptied further, and refusing a rename there
    /// would reject a patch the bridge validated, with an error describing
    /// something that did not happen.
    func testRenamingAnEmptyRoutineIsNotTreatedAsEmptyingIt() throws {
        let routine = Routine(name: "Lower A", sections: [])
        XCTAssertFalse(routine.canStartWorkout)

        let preview = try FlowRoutinePatcher.preview(
            patch: renamePatch(for: routine, to: "Lower B"),
            routines: [routine]
        )
        XCTAssertEqual(preview.updatedRoutine.name, "Lower B")
    }

    /// A patch that does the emptying is still refused.
    func testRemovingTheLastExerciseStillFailsAsWouldEmptyRoutine() throws {
        let exerciseId = UUID()
        let routine = Routine(name: "Upper A", sections: [
            Section(name: "Main", exercises: [
                ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
            ])
        ])
        let patch = FlowRoutinePatch(
            schemaVersion: 3,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Strip it back.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .removeExercise,
                    exerciseId: exerciseId,
                    expectedStringValue: "Press"
                )
            ]
        )

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
            guard case FlowRoutinePatchError.wouldEmptyRoutine = error else {
                return XCTFail("Expected wouldEmptyRoutine, got \(error)")
            }
        }
    }

    /// History written before schema 3 has no name to put back and must keep
    /// decoding rather than costing the user their undo depth.
    func testHistoryRecordsWrittenBeforeRenameStillDecode() throws {
        let json = """
        {
          "schemaVersion": 1,
          "records": [{
            "id": "\(UUID().uuidString)",
            "appliedAt": "2026-07-01T09:00:00Z",
            "routineId": "\(UUID().uuidString)",
            "routineName": "Upper A",
            "baseContentHash": "c1-0011223344556677",
            "appliedFromContentHash": "c1-0011223344556677",
            "resultingContentHash": "c1-7766554433221100",
            "rationale": "Written before schema 3.",
            "diffs": [],
            "previousSections": [],
            "outcome": "applied"
          }]
        }
        """
        let fixture = try makeFixture()
        let fileURL = fixture.directory.appendingPathComponent("coach-edit-history.json")
        try json.write(to: fileURL, atomically: true, encoding: .utf8)

        let history = CoachEditHistoryStore(fileURL: fileURL)

        XCTAssertEqual(history.records.count, 1)
        XCTAssertNil(history.records[0].previousName)
        XCTAssertEqual(history.records[0].routineName, "Upper A")
    }

    // MARK: - Schema 3: addSection

    /// Sections arrive empty, so the point of adding one is that a later
    /// operation in the same patch can fill it.
    func testAddSectionThenAddExerciseIntoItAppliesInOrder() throws {
        let routine = Routine(name: "Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press", sets: 3, reps: 8)])
        ])
        let sectionId = UUID()
        let exerciseId = UUID()
        let patch = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(
                kind: .addSection,
                section: FlowRoutinePatchSection(id: sectionId, name: "Core")
            ),
            FlowRoutinePatchOperation(
                kind: .addExercise,
                sectionId: sectionId,
                exercise: ExerciseBlock(id: exerciseId, name: "Hanging Leg Raise", sets: 3, reps: 12)
            )
        ])

        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: [routine])

        XCTAssertEqual(preview.updatedRoutine.sections.map(\.name), ["Main", "Core"])
        XCTAssertEqual(preview.updatedRoutine.sections[1].exercises.map(\.name), ["Hanging Leg Raise"])
        XCTAssertEqual(preview.diffs.map(\.title), ["Add section", "Add exercise"])
        XCTAssertEqual(preview.diffs[0].after, "Core (empty)")
    }

    func testAddSectionHonoursItsAnchor() throws {
        let first = UUID()
        let routine = Routine(name: "Upper A", sections: [
            Section(id: first, name: "Main", exercises: [ExerciseBlock(name: "Press")]),
            Section(name: "Accessories", exercises: [ExerciseBlock(name: "Curl")])
        ])
        let patch = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(
                kind: .addSection,
                afterSectionId: first,
                section: FlowRoutinePatchSection(id: UUID(), name: "Volume")
            )
        ])

        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: [routine])

        XCTAssertEqual(preview.updatedRoutine.sections.map(\.name), ["Main", "Volume", "Accessories"])
    }

    func testAddSectionWithAnUnknownAnchorIsRejected() throws {
        let routine = Routine(name: "Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])
        ])
        let unknown = UUID()
        let patch = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(
                kind: .addSection,
                afterSectionId: unknown,
                section: FlowRoutinePatchSection(id: UUID(), name: "Core")
            )
        ])

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
            guard case FlowRoutinePatchError.sectionNotFound(unknown) = error else {
                return XCTFail("Expected sectionNotFound, got \(error)")
            }
        }
    }

    func testAddSectionRefusesAnIdThatAlreadyExists() throws {
        let existing = UUID()
        let routine = Routine(name: "Upper A", sections: [
            Section(id: existing, name: "Main", exercises: [ExerciseBlock(name: "Press")])
        ])
        let patch = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(
                kind: .addSection,
                section: FlowRoutinePatchSection(id: existing, name: "Main again")
            )
        ])

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
            guard case FlowRoutinePatchError.duplicateSectionId(existing) = error else {
                return XCTFail("Expected duplicateSectionId, got \(error)")
            }
        }

        // And an id repeated within one patch, which the second operation only
        // sees because the first has already been applied to the working copy.
        let repeated = UUID()
        let twice = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(kind: .addSection, section: FlowRoutinePatchSection(id: repeated, name: "Core")),
            FlowRoutinePatchOperation(kind: .addSection, section: FlowRoutinePatchSection(id: repeated, name: "Core again"))
        ])
        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: twice, routines: [routine])) { error in
            guard case FlowRoutinePatchError.duplicateSectionId(repeated) = error else {
                return XCTFail("Expected duplicateSectionId, got \(error)")
            }
        }
    }

    func testAddSectionRefusesToPushPastTheSectionCeiling() throws {
        let sections = (0..<FlowRoutinePatcher.maximumSections).map {
            Section(name: "Section \($0)", exercises: [ExerciseBlock(name: "Press")])
        }
        let routine = Routine(name: "Upper A", sections: sections)
        let patch = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(
                kind: .addSection,
                section: FlowRoutinePatchSection(id: UUID(), name: "One too many")
            )
        ])

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
            guard case FlowRoutinePatchError.tooManySections(FlowRoutinePatcher.maximumSections) = error else {
                return XCTFail("Expected tooManySections, got \(error)")
            }
        }
    }

    func testAddSectionUpToTheCeilingIsAllowed() throws {
        let sections = (0..<(FlowRoutinePatcher.maximumSections - 1)).map {
            Section(name: "Section \($0)", exercises: [ExerciseBlock(name: "Press")])
        }
        let routine = Routine(name: "Upper A", sections: sections)
        let patch = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(
                kind: .addSection,
                section: FlowRoutinePatchSection(id: UUID(), name: "The last one that fits")
            )
        ])

        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: [routine])
        XCTAssertEqual(preview.updatedRoutine.sections.count, FlowRoutinePatcher.maximumSections)
    }

    /// The same invariant as the section ceiling: a section past this stops
    /// fitting in a snapshot, so the routine would quietly drop out of the
    /// coach's view at the next sync rather than fail anywhere visible.
    func testAddExerciseRefusesToPushASectionPastTheExerciseCeiling() throws {
        let sectionId = UUID()
        let full = (0..<FlowRoutinePatcher.maximumExercisesPerSection).map {
            ExerciseBlock(name: "Exercise \($0)")
        }
        let routine = Routine(name: "Upper A", sections: [
            Section(id: sectionId, name: "Main", exercises: full)
        ])
        let patch = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(
                kind: .addExercise,
                sectionId: sectionId,
                exercise: ExerciseBlock(name: "One too many")
            )
        ])

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
            guard case FlowRoutinePatchError.tooManyExercisesInSection("Main", FlowRoutinePatcher.maximumExercisesPerSection) = error else {
                return XCTFail("Expected tooManyExercisesInSection, got \(error)")
            }
        }
    }

    /// A move within one section takes the exercise out before putting it
    /// back, so a full section can always still be reordered.
    func testMovingWithinAFullSectionIsStillAllowed() throws {
        let sectionId = UUID()
        let movingId = UUID()
        var full = (0..<(FlowRoutinePatcher.maximumExercisesPerSection - 1)).map {
            ExerciseBlock(name: "Exercise \($0)")
        }
        full.append(ExerciseBlock(id: movingId, name: "Last"))
        let routine = Routine(name: "Upper A", sections: [
            Section(id: sectionId, name: "Main", exercises: full)
        ])
        let patch = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(kind: .moveExercise, exerciseId: movingId, targetSectionId: sectionId)
        ])

        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: [routine])
        XCTAssertEqual(preview.updatedRoutine.sections[0].exercises.count, FlowRoutinePatcher.maximumExercisesPerSection)
    }

    /// Flow resolves an anchor before inserting, so an exercise can never be
    /// placed after itself. The bridge has to agree, or it stores a draft the
    /// phone refuses to preview.
    func testAnExerciseCannotBeAnchoredOnItself() throws {
        let sectionId = UUID()
        let movingId = UUID()
        let routine = Routine(name: "Upper A", sections: [
            Section(id: sectionId, name: "Main", exercises: [
                ExerciseBlock(id: movingId, name: "Press"),
                ExerciseBlock(name: "Row")
            ])
        ])

        let added = UUID()
        let addingOntoItself = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(
                kind: .addExercise,
                sectionId: sectionId,
                afterExerciseId: added,
                exercise: ExerciseBlock(id: added, name: "Face Pull")
            )
        ])
        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: addingOntoItself, routines: [routine])) { error in
            guard case FlowRoutinePatchError.exerciseNotFound(added) = error else {
                return XCTFail("Expected exerciseNotFound, got \(error)")
            }
        }

        let movingOntoItself = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(
                kind: .moveExercise,
                exerciseId: movingId,
                targetSectionId: sectionId,
                afterExerciseId: movingId
            )
        ])
        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: movingOntoItself, routines: [routine])) { error in
            guard case FlowRoutinePatchError.exerciseNotFound(movingId) = error else {
                return XCTFail("Expected exerciseNotFound, got \(error)")
            }
        }
    }

    func testTwoRenamesInOnePatchChainFromEachOther() throws {
        let routine = Routine(name: "Wednesday — Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])
        ])
        let patch = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(
                kind: .renameRoutine,
                expectedStringValue: "Wednesday — Upper A",
                newStringValue: "Upper A"
            ),
            FlowRoutinePatchOperation(
                kind: .renameRoutine,
                expectedStringValue: "Upper A",
                newStringValue: "Upper A (heavy)"
            )
        ])

        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: [routine])
        XCTAssertEqual(preview.updatedRoutine.name, "Upper A (heavy)")
    }

    func testAddSectionBoundsAndTrimsItsName() throws {
        let routine = Routine(name: "Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])
        ])

        for candidate in ["   ", String(repeating: "x", count: 201)] {
            let patch = sectionPatch(for: routine, operations: [
                FlowRoutinePatchOperation(
                    kind: .addSection,
                    section: FlowRoutinePatchSection(id: UUID(), name: candidate)
                )
            ])
            XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
                guard case FlowRoutinePatchError.invalidValue("section.name", _) = error else {
                    return XCTFail("Expected invalidValue for \"\(candidate)\", got \(error)")
                }
            }
        }

        let padded = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(
                kind: .addSection,
                section: FlowRoutinePatchSection(id: UUID(), name: "  Core  ")
            )
        ])
        let preview = try FlowRoutinePatcher.preview(patch: padded, routines: [routine])
        XCTAssertEqual(preview.updatedRoutine.sections.last?.name, "Core")
    }

    func testAddSectionIsRejectedInASchemaTwoPatch() throws {
        let routine = Routine(name: "Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])
        ])
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "A section under the version that predates sections.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .addSection,
                    section: FlowRoutinePatchSection(id: UUID(), name: "Core")
                )
            ]
        )

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
            guard case FlowRoutinePatchError.operationNeedsNewerSchema("addSection", 3, 2) = error else {
                return XCTFail("Expected operationNeedsNewerSchema, got \(error)")
            }
        }
    }

    /// An empty section adds no steps, so it must not make a routine that
    /// could start a workout look like one that cannot.
    func testAddingAnEmptySectionKeepsTheRoutineStartable() throws {
        let routine = Routine(name: "Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press", sets: 3, reps: 8)])
        ])
        let patch = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(
                kind: .addSection,
                section: FlowRoutinePatchSection(id: UUID(), name: "Core")
            )
        ])

        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: [routine])
        XCTAssertTrue(preview.updatedRoutine.canStartWorkout)
    }

    func testAddSectionAppliesThroughTheStoreAndIsRestorable() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let history = CoachEditHistoryStore(
            fileURL: fixture.directory.appendingPathComponent("coach-edit-history.json")
        )
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults, editHistory: history)
        let routine = Routine(name: "Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press", sets: 3, reps: 8)])
        ])
        store.addRoutine(routine)

        let sectionId = UUID()
        let patch = sectionPatch(for: routine, operations: [
            FlowRoutinePatchOperation(kind: .addSection, section: FlowRoutinePatchSection(id: sectionId, name: "Core")),
            FlowRoutinePatchOperation(
                kind: .addExercise,
                sectionId: sectionId,
                exercise: ExerciseBlock(name: "Hanging Leg Raise", sets: 3, reps: 12)
            )
        ])
        guard case .success(let preview) = store.previewRoutinePatchJSON(try patchJSON(patch)),
              case .success = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected the section patch to apply")
        }
        XCTAssertEqual(store.routines[0].sections.map(\.name), ["Main", "Core"])

        let record = try XCTUnwrap(history.mostRecentRestorable)
        guard case .success = store.restoreCoachEdit(record) else {
            return XCTFail("Expected restore to succeed")
        }
        XCTAssertEqual(store.routines[0].sections.map(\.name), ["Main"])
    }

    // MARK: - Schema 3: createRoutine

    func testCreateRoutinePreviewsAsAdditionsAndApplies() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let history = CoachEditHistoryStore(
            fileURL: fixture.directory.appendingPathComponent("coach-edit-history.json")
        )
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults, editHistory: history)
        let created = newRoutine(name: "Lower A", phase: .deload)

        guard case .success(let preview) = store.previewRoutinePatchJSON(try patchJSON(createPatch(created))) else {
            return XCTFail("Expected the create to preview")
        }
        XCTAssertTrue(preview.isCreate)
        XCTAssertNil(preview.originalRoutine)
        XCTAssertEqual(preview.diffs.first?.title, "Create routine")
        XCTAssertTrue(preview.diffs.allSatisfy { $0.before == "[not present]" })
        // One row for the routine, one per section, one per exercise.
        XCTAssertEqual(preview.diffs.count, 1 + 2 + 3)
        XCTAssertEqual(Set(preview.diffs.map(\.id)).count, preview.diffs.count)
        XCTAssertTrue(store.routines.isEmpty)

        guard case .success(let applied) = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected the create to apply")
        }
        XCTAssertEqual(store.routines.count, 1)
        XCTAssertEqual(applied.id, created.id)
        XCTAssertEqual(store.routines[0].name, "Lower A")
        XCTAssertEqual(store.routines[0].currentPhase, .deload)
        XCTAssertEqual(store.routines[0].sections.map(\.name), ["Main Lifts", "Accessories"])
        XCTAssertTrue(store.routines[0].canStartWorkout)
    }

    /// The client supplies every id, which is what makes a create idempotent:
    /// the second attempt has nothing new to add.
    func testApplyingTheSameCreateTwiceLeavesOneRoutine() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let created = newRoutine(name: "Lower A")
        let json = try patchJSON(createPatch(created))

        guard case .success(let preview) = store.previewRoutinePatchJSON(json),
              case .success = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected the first create to apply")
        }
        XCTAssertEqual(store.routines.count, 1)

        // Re-applying the preview object that is still on screen.
        guard case .failure(let staleApply) = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected the second apply to refuse")
        }
        XCTAssertEqual(staleApply, .routineAlreadyExists(created.id))

        // And previewing the same patch text again, which is what a retried
        // bridge delivery looks like.
        guard case .failure(let stalePreview) = store.previewRoutinePatchJSON(json) else {
            return XCTFail("Expected the second preview to refuse")
        }
        XCTAssertEqual(stalePreview, .routineAlreadyExists(created.id))
        XCTAssertEqual(store.routines.count, 1)
    }

    /// A retry that already landed is not a failure, and the inbox should not
    /// dress it up as one.
    func testASupersededCreateIsReportedAsAlreadyApplied() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let created = newRoutine(name: "Lower A")
        let json = try patchJSON(createPatch(created))
        let inbox = CoachPatchInbox(fileURL: fixture.directory.appendingPathComponent("inbox.json"))
        inbox.enqueue(rawJSON: json, source: .paste)

        let before = try XCTUnwrap(inbox.pending.first)
        let readyState = inbox.summary(for: before, routines: store.routines)
        XCTAssertEqual(readyState.readiness, .ready)
        XCTAssertTrue(readyState.isCreate)
        XCTAssertEqual(readyState.routineName, "Lower A")

        store.addRoutine(created)

        let summary = inbox.summary(for: before, routines: store.routines)
        guard case .superseded = summary.readiness else {
            return XCTFail("Expected superseded, got \(summary.readiness)")
        }
        XCTAssertTrue(summary.isCreate)
    }

    func testUndoingACreateRemovesTheRoutine() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let history = CoachEditHistoryStore(
            fileURL: fixture.directory.appendingPathComponent("coach-edit-history.json")
        )
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults, editHistory: history)
        let created = newRoutine(name: "Lower A")

        guard case .success(let preview) = store.previewRoutinePatchJSON(try patchJSON(createPatch(created))),
              case .success = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected the create to apply")
        }

        let record = try XCTUnwrap(history.mostRecentRestorable)
        XCTAssertTrue(record.wasCreate)
        guard case .success(let removed) = store.restoreCoachEdit(record) else {
            return XCTFail("Expected undo to remove the routine")
        }
        XCTAssertEqual(removed.id, created.id)
        XCTAssertTrue(store.routines.isEmpty)
        XCTAssertEqual(history.newestFirst.first?.outcome, .restored)
        XCTAssertNil(history.mostRecentRestorable)
    }

    /// Undo of a create deletes, so the guard against later edits matters more
    /// here than anywhere else.
    func testUndoingACreateRefusesOnceTheRoutineHasBeenEdited() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let history = CoachEditHistoryStore(
            fileURL: fixture.directory.appendingPathComponent("coach-edit-history.json")
        )
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults, editHistory: history)
        let created = newRoutine(name: "Lower A")

        guard case .success(let preview) = store.previewRoutinePatchJSON(try patchJSON(createPatch(created))),
              case .success = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected the create to apply")
        }

        var edited = store.routines[0]
        edited.sections[0].exercises[0].sets = 5
        store.updateRoutine(edited)

        let record = try XCTUnwrap(history.mostRecentRestorable)
        guard case .failure(let error) = store.restoreCoachEdit(record) else {
            return XCTFail("Expected undo to refuse a routine edited since the create")
        }
        XCTAssertEqual(error, .routineChangedSinceEdit("Lower A"))
        XCTAssertEqual(store.routines.count, 1)

        guard case .success = store.restoreCoachEdit(record, allowingOverwrite: true) else {
            return XCTFail("Expected an explicit overwrite to remove it")
        }
        XCTAssertTrue(store.routines.isEmpty)
    }

    func testCreateMustCarryExactlyOneCreateOperation() throws {
        let created = newRoutine(name: "Lower A")
        var patch = createPatch(created)
        patch = FlowRoutinePatch(
            schemaVersion: 3,
            target: .newRoutine,
            rationale: patch.rationale,
            operations: patch.operations + [
                FlowRoutinePatchOperation(
                    kind: .addSection,
                    section: FlowRoutinePatchSection(id: UUID(), name: "Core")
                )
            ]
        )

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [])) { error in
            guard case FlowRoutinePatchError.createMustStandAlone = error else {
                return XCTFail("Expected createMustStandAlone, got \(error)")
            }
        }
    }

    func testACreateCarriesNoAnchor() throws {
        let created = newRoutine(name: "Lower A")
        let patch = FlowRoutinePatch(
            schemaVersion: 3,
            target: .newRoutine,
            routineId: UUID(),
            rationale: "Anchored to something it cannot be anchored to.",
            operations: createPatch(created).operations
        )

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [])) { error in
            guard case FlowRoutinePatchError.invalidValue("target", _) = error else {
                return XCTFail("Expected invalidValue on target, got \(error)")
            }
        }
    }

    func testCreateRoutineIsRejectedInAnExistingRoutinePatch() throws {
        let routine = Routine(name: "Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])
        ])
        let patch = sectionPatch(for: routine, operations: createPatch(newRoutine(name: "Lower A")).operations)

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
            guard case FlowRoutinePatchError.invalidValue("target", _) = error else {
                return XCTFail("Expected invalidValue on target, got \(error)")
            }
        }
    }

    func testCreatedRoutineExerciseIdsMustBeFreshEverywhere() throws {
        let borrowedId = UUID()
        let existing = Routine(name: "Upper A", sections: [
            Section(name: "Main", exercises: [ExerciseBlock(id: borrowedId, name: "Press")])
        ])
        var created = newRoutine(name: "Lower A")
        created.sections[0].exercises[0].id = borrowedId

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: createPatch(created), routines: [existing])) { error in
            guard case FlowRoutinePatchError.duplicateExerciseId(borrowedId) = error else {
                return XCTFail("Expected duplicateExerciseId, got \(error)")
            }
        }
    }

    func testCreatedRoutineMustHaveSomethingToDo() throws {
        var created = newRoutine(name: "Lower A")
        created.sections = [Section(name: "Empty", exercises: [])]

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: createPatch(created), routines: [])) { error in
            guard case FlowRoutinePatchError.wouldEmptyRoutine = error else {
                return XCTFail("Expected wouldEmptyRoutine, got \(error)")
            }
        }

        var noSections = newRoutine(name: "Lower A")
        noSections.sections = []
        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: createPatch(noSections), routines: [])) { error in
            guard case FlowRoutinePatchError.invalidValue("routine.sections", _) = error else {
                return XCTFail("Expected invalidValue on routine.sections, got \(error)")
            }
        }
    }

    func testCreateIsRejectedInASchemaTwoPatch() throws {
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            target: .newRoutine,
            rationale: "A create under the version that predates creates.",
            operations: createPatch(newRoutine(name: "Lower A")).operations
        )

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [])) { error in
            guard case FlowRoutinePatchError.operationNeedsNewerSchema("createRoutine", 3, 2) = error else {
                return XCTFail("Expected operationNeedsNewerSchema, got \(error)")
            }
        }
    }

    /// A pasted create has no routineId, so detection keyed on one would send
    /// it to the routine importer to fail with a decode error.
    func testAPastedCreateIsRecognisedAsACoachPatch() throws {
        let json = try patchJSON(createPatch(newRoutine(name: "Lower A")))

        XCTAssertEqual(FlowRoutineExchange.detectPayload(in: json), .coachPatch)

        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        guard case .failure(let error) = store.importRoutineFromJSON(json) else {
            return XCTFail("Expected the routine importer to refuse a coach patch")
        }
        guard case .looksLikeCoachPatch = error else {
            return XCTFail("Expected looksLikeCoachPatch, got \(error)")
        }
    }

    private func newRoutine(name: String, phase: WorkoutPhase = .base) -> Routine {
        Routine(
            id: UUID(),
            name: name,
            sections: [
                Section(name: "Main Lifts", exercises: [
                    ExerciseBlock(name: "Trap Bar Deadlift", sets: 3, reps: 5),
                    ExerciseBlock(name: "Split Squat", sets: 3, reps: 8)
                ]),
                Section(name: "Accessories", exercises: [
                    ExerciseBlock(name: "Calf Raise", sets: 3, reps: 12)
                ])
            ],
            currentPhase: phase
        )
    }

    private func createPatch(_ routine: Routine) -> FlowRoutinePatch {
        FlowRoutinePatch(
            schemaVersion: 3,
            target: .newRoutine,
            rationale: "The split needs a lower day that does not exist yet.",
            operations: [FlowRoutinePatchOperation(kind: .createRoutine, routine: routine)]
        )
    }

    private func sectionPatch(
        for routine: Routine,
        operations: [FlowRoutinePatchOperation]
    ) -> FlowRoutinePatch {
        FlowRoutinePatch(
            schemaVersion: 3,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Restructure the block rather than just its numbers.",
            operations: operations
        )
    }

    private func renamePatch(for routine: Routine, to newName: String) -> FlowRoutinePatch {
        FlowRoutinePatch(
            schemaVersion: 3,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "The weekday in the name no longer matches the plan.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .renameRoutine,
                    expectedStringValue: routine.name,
                    newStringValue: newName
                )
            ]
        )
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
