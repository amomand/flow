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

    func testStoreAppliesPatchWithRestorableBackup() throws {
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

        let restored = store.restoreLastCoachPatchBackup()
        XCTAssertEqual(restored?.id, routine.id)
        XCTAssertEqual(store.routines[0].sections[0].exercises[0].reps, 8)
    }

    func testStoreRejectsStalePatchWithoutMutatingRoutine() throws {
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

        let result = store.previewRoutinePatchJSON(try patchJSON(patch))

        guard case .failure(.staleRoutine(_, _)) = result else {
            return XCTFail("Expected stale patch rejection")
        }
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

    func testContentChangeStillStalesPatch() throws {
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

        routine.sections[0].exercises[0].sets = 4

        XCTAssertThrowsError(try FlowRoutinePatcher.preview(patch: patch, routines: [routine])) { error in
            guard case FlowRoutinePatchError.staleRoutine = error else {
                return XCTFail("Expected staleRoutine, got \(error)")
            }
        }
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
