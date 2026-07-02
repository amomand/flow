import XCTest
@testable import Flow

final class RoutineStoreTests: XCTestCase {
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
