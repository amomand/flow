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
            schemaVersion: 1,
            routineId: routine.id,
            baseRoutineHash: FlowRoutineRevision.hash(for: routine),
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
            schemaVersion: 1,
            routineId: routine.id,
            baseRoutineHash: FlowRoutineRevision.hash(for: routine),
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
            schemaVersion: 1,
            routineId: routine.id,
            baseRoutineHash: "stale",
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

    private func patchJSON(_ patch: FlowRoutinePatch) throws -> String {
        let data = try FlowCoachCoding.encoder().encode(patch)
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
