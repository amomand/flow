import XCTest
@testable import Flow

final class RoutineStoreTests: XCTestCase {
    private enum SimulatedWriteError: Error {
        case failed
    }

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

    func testMissingRoutineFileSeedsNormally() throws {
        let fixture = try makeFixture()

        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)

        XCTAssertFalse(store.routines.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    func testCorruptExistingRoutineFileIsNotOverwritten() throws {
        let fixture = try makeFixture()
        let badJSON = "{ not valid json"
        try badJSON.write(to: fixture.fileURL, atomically: true, encoding: .utf8)

        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)

        XCTAssertTrue(store.routines.isEmpty)
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(try String(contentsOf: fixture.fileURL, encoding: .utf8), badJSON)
        let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .filter { $0.hasPrefix("routines.corrupt-") }
        XCTAssertEqual(backups.count, 1)
    }

    func testValidEmptyRoutineFileDoesNotReseed() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)

        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)

        XCTAssertTrue(store.routines.isEmpty)
        XCTAssertNil(store.loadError)
    }

    func testImportAssignsFreshIds() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let original = Routine(
            id: UUID(),
            name: "Import Me",
            sections: [
                Section(id: UUID(), name: "Main", exercises: [
                    ExerciseBlock(id: UUID(), name: "Press", sets: 2, reps: 8)
                ])
            ]
        )
        let data = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        let result = store.importRoutineFromJSON(json)

        guard case .success(let imported) = result else {
            return XCTFail("Import failed")
        }
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertNotEqual(imported.sections[0].id, original.sections[0].id)
        XCTAssertNotEqual(imported.sections[0].exercises[0].id, original.sections[0].exercises[0].id)
    }

    func testImportToleratesCodeFencesAndProse() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let original = Routine(
            name: "Fenced",
            sections: [Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])]
        )
        let data = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let wrapped = "Here is your routine:\n```json\n\(json)\n```\nEnjoy."

        let result = store.importRoutineFromJSON(wrapped)

        guard case .success(let imported) = result else {
            return XCTFail("Import failed")
        }
        XCTAssertEqual(imported.name, "Fenced")
    }

    func testImportOfCoachPatchGivesHelpfulError() throws {
        let fixture = try makeFixture()
        try "[]".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let store = RoutineStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let routine = Routine(
            name: "Target",
            sections: [Section(name: "Main", exercises: [ExerciseBlock(name: "Press", sets: 3, reps: 8)])]
        )
        store.addRoutine(routine)
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Not a routine.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseReps,
                    exerciseId: routine.sections[0].exercises[0].id,
                    expectedIntValue: 8,
                    newIntValue: 10
                )
            ]
        )
        let json = try XCTUnwrap(String(data: FlowRoutineExchange.encoder().encode(patch), encoding: .utf8))

        let result = store.importRoutineFromJSON(json)

        guard case .failure(let error) = result else {
            return XCTFail("Expected import to be rejected")
        }
        guard case .looksLikeCoachPatch = error else {
            return XCTFail("Expected looksLikeCoachPatch, got \(error)")
        }
        XCTAssertEqual(store.routines.count, 1)
    }

    func testSaveFailureIsReportedAndDoesNotLeaveUnsavedMutationInMemory() throws {
        let fixture = try makeFixture()
        let unwritableURL = fixture.directory
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("routines.json")
        let store = RoutineStore(fileURL: unwritableURL, defaults: fixture.defaults)
        store.routines = []
        let routine = Routine(
            name: "Unsaved",
            sections: [Section(name: "Main", exercises: [ExerciseBlock(name: "Press")])]
        )

        let result = store.addRoutine(routine)

        guard case .failure = result else {
            return XCTFail("Expected the write to fail")
        }
        XCTAssertTrue(store.routines.isEmpty)
        XCTAssertNotNil(store.saveError)
    }

    func testCoachApplyDoesNotReportSuccessWhenRoutineWriteFails() throws {
        let fixture = try makeFixture()
        let unwritableURL = fixture.directory
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("routines.json")
        let history = CoachEditHistoryStore(fileURL: fixture.directory.appendingPathComponent("history.json"))
        let store = RoutineStore(fileURL: unwritableURL, defaults: fixture.defaults, editHistory: history)
        let exerciseId = UUID()
        let routine = Routine(
            name: "Coach",
            sections: [Section(name: "Main", exercises: [
                ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
            ])]
        )
        store.routines = [routine]
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Test disk failure.",
            operations: [FlowRoutinePatchOperation(
                kind: .replaceExerciseReps,
                exerciseId: exerciseId,
                expectedIntValue: 8,
                newIntValue: 10
            )]
        )
        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: store.routines)

        let result = store.applyRoutinePatchPreview(preview)

        guard case .failure(.persistenceFailed) = result else {
            return XCTFail("Expected a persistence failure, got \(result)")
        }
        XCTAssertEqual(store.routines[0].sections[0].exercises[0].reps, 8)
        XCTAssertTrue(history.records.isEmpty)
    }

    func testApplyRollbackFailureKeepsMemoryAlignedWithUpdatedDisk() throws {
        let fixture = try makeFixture()
        let exerciseId = UUID()
        let current = Routine(
            name: "Coach",
            sections: [Section(name: "Main", exercises: [
                ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
            ])]
        )
        try JSONEncoder().encode([current]).write(to: fixture.fileURL)
        let history = CoachEditHistoryStore(
            fileURL: fixture.directory
                .appendingPathComponent("missing", isDirectory: true)
                .appendingPathComponent("history.json")
        )
        var routineWriteCount = 0
        let store = RoutineStore(
            fileURL: fixture.fileURL,
            defaults: fixture.defaults,
            editHistory: history,
            fileWriter: { data, url in
                routineWriteCount += 1
                guard routineWriteCount == 1 else { throw SimulatedWriteError.failed }
                try data.write(to: url, options: .atomic)
            }
        )
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: current.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: current),
            exportedAt: nil,
            rationale: "Exercise rollback failure.",
            operations: [FlowRoutinePatchOperation(
                kind: .replaceExerciseReps,
                exerciseId: exerciseId,
                expectedIntValue: 8,
                newIntValue: 10
            )]
        )
        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: store.routines)

        let result = store.applyRoutinePatchPreview(preview)

        guard case .failure(.persistenceFailed) = result else {
            return XCTFail("Expected a persistence failure, got \(result)")
        }
        XCTAssertEqual(store.routines[0].sections[0].exercises[0].reps, 10)
        let disk = try JSONDecoder().decode([Routine].self, from: Data(contentsOf: fixture.fileURL))
        XCTAssertEqual(disk[0].sections[0].exercises[0].reps, 10)
    }

    func testRestoreRollbackFailureKeepsMemoryAlignedWithRestoredDisk() throws {
        let fixture = try makeFixture()
        let exerciseId = UUID()
        let original = Routine(
            name: "Coach",
            sections: [Section(name: "Main", exercises: [
                ExerciseBlock(id: exerciseId, name: "Press", sets: 3, reps: 8)
            ])]
        )
        var edited = original
        edited.sections[0].exercises[0].reps = 10
        try JSONEncoder().encode([edited]).write(to: fixture.fileURL)

        var historyWriteCount = 0
        let history = CoachEditHistoryStore(
            fileURL: fixture.directory.appendingPathComponent("history.json"),
            fileWriter: { data, url in
                historyWriteCount += 1
                guard historyWriteCount == 1 else { throw SimulatedWriteError.failed }
                try data.write(to: url, options: .atomic)
            }
        )
        let record = CoachEditRecord(
            id: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1_000),
            routineId: edited.id,
            routineName: edited.name,
            baseContentHash: FlowRoutineRevision.contentHash(for: original),
            appliedFromContentHash: FlowRoutineRevision.contentHash(for: original),
            resultingContentHash: FlowRoutineRevision.contentHash(for: edited),
            rationale: "Exercise restore rollback failure.",
            diffs: [],
            previousSections: original.sections,
            previousName: original.name,
            createdRoutine: false,
            provenance: nil,
            outcome: .applied,
            restoredAt: nil
        )
        guard case .success = history.record(record) else {
            return XCTFail("Expected history fixture to persist")
        }

        var routineWriteCount = 0
        let store = RoutineStore(
            fileURL: fixture.fileURL,
            defaults: fixture.defaults,
            editHistory: history,
            fileWriter: { data, url in
                routineWriteCount += 1
                guard routineWriteCount == 1 else { throw SimulatedWriteError.failed }
                try data.write(to: url, options: .atomic)
            }
        )

        let result = store.restoreCoachEdit(record)

        guard case .failure(.persistenceFailed) = result else {
            return XCTFail("Expected a persistence failure, got \(result)")
        }
        XCTAssertEqual(store.routines[0].sections[0].exercises[0].reps, 8)
        let disk = try JSONDecoder().decode([Routine].self, from: Data(contentsOf: fixture.fileURL))
        XCTAssertEqual(disk[0].sections[0].exercises[0].reps, 8)
        XCTAssertEqual(history.records.first?.outcome, .applied)
    }

    private func makeFixture() throws -> (directory: URL, fileURL: URL, defaults: UserDefaults) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)

        let suiteName = "FlowTests-\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        return (directory, directory.appendingPathComponent("routines.json"), defaults)
    }
}
