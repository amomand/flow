import XCTest
@testable import Flow

final class CoachEditHistoryTests: XCTestCase {
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

    func testApplyRecordsAuditEntryWithMetadataAndProvenance() throws {
        let fixture = try makeFixture()
        let (store, history) = try makeStores(fixture)
        let (routine, exerciseId) = seedRoutine(in: store)
        let baseHash = FlowRoutineRevision.contentHash(for: routine)
        let preview = try FlowRoutinePatcher.preview(
            patch: makePatch(routine: routine, exerciseId: exerciseId, baseContentHash: baseHash),
            routines: store.routines
        )
        let provenance = CoachEditProvenance(
            sourcePatchId: UUID(),
            contextId: nil,
            assistantProvider: "claude",
            source: .deepLink
        )

        guard case .success(let updated) = store.applyRoutinePatchPreview(preview, provenance: provenance) else {
            return XCTFail("Expected apply to succeed")
        }

        XCTAssertEqual(history.records.count, 1)
        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(record.routineId, routine.id)
        XCTAssertEqual(record.routineName, "Coach")
        XCTAssertEqual(record.baseContentHash, baseHash)
        XCTAssertEqual(record.appliedFromContentHash, baseHash)
        XCTAssertFalse(record.wasRebased)
        XCTAssertEqual(record.resultingContentHash, FlowRoutineRevision.contentHash(for: updated))
        XCTAssertEqual(record.rationale, "Progress pressing volume.")
        XCTAssertEqual(record.diffs.count, 1)
        XCTAssertEqual(record.previousSections, routine.sections)
        XCTAssertEqual(record.provenance, provenance)
        XCTAssertEqual(record.outcome, .applied)
        XCTAssertNil(record.restoredAt)
    }

    func testRebasedApplyRecordsBothHashes() throws {
        let fixture = try makeFixture()
        let (store, history) = try makeStores(fixture)
        let (routine, exerciseId) = seedRoutine(in: store)
        // Pin the patch to a hash that is stale by the time it applies.
        let patch = makePatch(routine: routine, exerciseId: exerciseId, baseContentHash: "c1-stale")
        let preview = try FlowRoutinePatcher.preview(patch: patch, routines: store.routines)

        guard case .success = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected rebased apply to succeed")
        }

        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(record.baseContentHash, "c1-stale")
        XCTAssertEqual(record.appliedFromContentHash, FlowRoutineRevision.contentHash(for: routine))
        XCTAssertTrue(record.wasRebased)
    }

    func testAuditEntrySurvivesRelaunchAndRestoresThroughRoutineStore() throws {
        let fixture = try makeFixture()
        let (store, _) = try makeStores(fixture)
        let (routine, exerciseId) = seedRoutine(in: store)
        let preview = try FlowRoutinePatcher.preview(
            patch: makePatch(
                routine: routine,
                exerciseId: exerciseId,
                baseContentHash: FlowRoutineRevision.contentHash(for: routine)
            ),
            routines: store.routines
        )
        guard case .success = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected apply to succeed")
        }

        // Fresh store instances over the same files: the relaunch case.
        let (relaunchedStore, relaunchedHistory) = try makeStores(fixture)
        XCTAssertEqual(relaunchedStore.routines[0].sections[0].exercises[0].reps, 10)
        let record = try XCTUnwrap(relaunchedHistory.mostRecentRestorable)

        guard case .success(let restored) = relaunchedStore.restoreCoachEdit(record) else {
            return XCTFail("Expected restore to succeed after relaunch")
        }
        XCTAssertEqual(restored.sections[0].exercises[0].reps, 8)

        // The rollback is persisted through the normal save path, and the
        // record's outcome flip survives another relaunch.
        let (verifyStore, verifyHistory) = try makeStores(fixture)
        XCTAssertEqual(verifyStore.routines[0].sections[0].exercises[0].reps, 8)
        let verified = try XCTUnwrap(verifyHistory.records.first)
        XCTAssertEqual(verified.outcome, .restored)
        XCTAssertNotNil(verified.restoredAt)
        XCTAssertNil(verifyHistory.mostRecentRestorable)
    }

    func testRestorePreservesPhaseToggledAfterApply() throws {
        let fixture = try makeFixture()
        let (store, history) = try makeStores(fixture)
        let (routine, exerciseId) = seedRoutine(in: store)
        let preview = try FlowRoutinePatcher.preview(
            patch: makePatch(
                routine: routine,
                exerciseId: exerciseId,
                baseContentHash: FlowRoutineRevision.contentHash(for: routine)
            ),
            routines: store.routines
        )
        guard case .success = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected apply to succeed")
        }

        // The phase toggles after the edit; restoring the edit must not
        // revert it. Phase is not content, so restore does not refuse either.
        var toggled = store.routines[0]
        toggled.currentPhase = .peak
        store.updateRoutine(toggled)

        let record = try XCTUnwrap(history.mostRecentRestorable)
        guard case .success(let restored) = store.restoreCoachEdit(record) else {
            return XCTFail("Expected restore to succeed")
        }
        XCTAssertEqual(restored.currentPhase, .peak)
        XCTAssertEqual(restored.sections[0].exercises[0].reps, 8)
    }

    func testRestoreRefusesWhenRoutineChangedUnlessOverwriteAllowed() throws {
        let fixture = try makeFixture()
        let (store, history) = try makeStores(fixture)
        let (routine, exerciseId) = seedRoutine(in: store)
        let preview = try FlowRoutinePatcher.preview(
            patch: makePatch(
                routine: routine,
                exerciseId: exerciseId,
                baseContentHash: FlowRoutineRevision.contentHash(for: routine)
            ),
            routines: store.routines
        )
        guard case .success = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected apply to succeed")
        }

        // A manual edit lands after the coach edit.
        var edited = store.routines[0]
        edited.sections[0].exercises[0].sets = 5
        store.updateRoutine(edited)

        let record = try XCTUnwrap(history.mostRecentRestorable)
        guard case .failure(.routineChangedSinceEdit) = store.restoreCoachEdit(record) else {
            return XCTFail("Expected restore to refuse without overwrite")
        }
        XCTAssertEqual(store.routines[0].sections[0].exercises[0].sets, 5)
        XCTAssertEqual(history.records.first?.outcome, .applied)

        guard case .success(let restored) = store.restoreCoachEdit(record, allowingOverwrite: true) else {
            return XCTFail("Expected explicit overwrite restore to succeed")
        }
        XCTAssertEqual(restored.sections[0].exercises[0].reps, 8)
        XCTAssertEqual(restored.sections[0].exercises[0].sets, 3)
        XCTAssertEqual(history.records.first?.outcome, .restored)
    }

    func testRestoreFailsForDeletedRoutine() throws {
        let fixture = try makeFixture()
        let (store, history) = try makeStores(fixture)
        let (routine, exerciseId) = seedRoutine(in: store)
        let preview = try FlowRoutinePatcher.preview(
            patch: makePatch(
                routine: routine,
                exerciseId: exerciseId,
                baseContentHash: FlowRoutineRevision.contentHash(for: routine)
            ),
            routines: store.routines
        )
        guard case .success = store.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected apply to succeed")
        }
        store.deleteRoutine(at: IndexSet(integer: 0))

        let record = try XCTUnwrap(history.mostRecentRestorable)
        guard case .failure(.routineNotFound) = store.restoreCoachEdit(record) else {
            return XCTFail("Expected routineNotFound")
        }
        XCTAssertEqual(history.records.first?.outcome, .applied)
    }

    func testCorruptHistoryFileStartsEmptyAndCannotTouchRoutines() throws {
        let fixture = try makeFixture()
        let (store, _) = try makeStores(fixture)
        let (routine, exerciseId) = seedRoutine(in: store)
        let routinesBefore = try Data(contentsOf: fixture.routinesURL)
        try "corrupt {".write(to: fixture.historyURL, atomically: true, encoding: .utf8)

        let (freshStore, freshHistory) = try makeStores(fixture)

        XCTAssertTrue(freshHistory.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.routinesURL), routinesBefore)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(siblings.contains { $0.lastPathComponent.hasPrefix("coach-edit-history.corrupt-") })

        // Applying still works and rebuilds a valid history file.
        let preview = try FlowRoutinePatcher.preview(
            patch: makePatch(
                routine: routine,
                exerciseId: exerciseId,
                baseContentHash: FlowRoutineRevision.contentHash(for: routine)
            ),
            routines: freshStore.routines
        )
        guard case .success = freshStore.applyRoutinePatchPreview(preview) else {
            return XCTFail("Expected apply to succeed after corrupt history")
        }
        XCTAssertEqual(freshHistory.records.count, 1)
        XCTAssertEqual(CoachEditHistoryStore(fileURL: fixture.historyURL).records.count, 1)
    }

    func testHistoryPrunesOldestBeyondMaxRecords() throws {
        let fixture = try makeFixture()
        let history = CoachEditHistoryStore(fileURL: fixture.historyURL)

        for index in 0..<(CoachEditHistoryStore.maxRecords + 3) {
            history.record(makeSyntheticRecord(
                appliedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
                routineName: "Routine \(index)"
            ))
        }

        XCTAssertEqual(history.records.count, CoachEditHistoryStore.maxRecords)
        XCTAssertEqual(history.newestFirst.first?.routineName, "Routine 22")
        XCTAssertEqual(history.newestFirst.last?.routineName, "Routine 3")
    }

    func testHistoryWriteFailureIsVisibleAndRollsBackInMemoryRecord() throws {
        let fixture = try makeFixture()
        let unwritableURL = fixture.directory
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("coach-edit-history.json")
        let history = CoachEditHistoryStore(fileURL: unwritableURL)

        let result = history.record(makeSyntheticRecord(
            appliedAt: Date(timeIntervalSince1970: 1_000),
            routineName: "Unsaved"
        ))

        guard case .failure = result else {
            return XCTFail("Expected the write to fail")
        }
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertNotNil(history.persistenceError)
    }

    // MARK: - Helpers

    private struct Fixture {
        let directory: URL
        let routinesURL: URL
        let historyURL: URL
        let defaults: UserDefaults
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoachEditHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)

        let suiteName = "CoachEditHistoryTests-\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        let routinesURL = directory.appendingPathComponent("routines.json")
        if !FileManager.default.fileExists(atPath: routinesURL.path) {
            try "[]".write(to: routinesURL, atomically: true, encoding: .utf8)
        }

        return Fixture(
            directory: directory,
            routinesURL: routinesURL,
            historyURL: directory.appendingPathComponent("coach-edit-history.json"),
            defaults: defaults
        )
    }

    private func makeStores(_ fixture: Fixture) throws -> (RoutineStore, CoachEditHistoryStore) {
        let history = CoachEditHistoryStore(fileURL: fixture.historyURL)
        let store = RoutineStore(fileURL: fixture.routinesURL, defaults: fixture.defaults, editHistory: history)
        return (store, history)
    }

    @discardableResult
    private func seedRoutine(in store: RoutineStore) -> (Routine, UUID) {
        if let existing = store.routines.first {
            return (existing, existing.sections[0].exercises[0].id)
        }
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
        return (routine, exerciseId)
    }

    private func makePatch(routine: Routine, exerciseId: UUID, baseContentHash: String) -> FlowRoutinePatch {
        FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: baseContentHash,
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
    }

    private func makeSyntheticRecord(appliedAt: Date, routineName: String) -> CoachEditRecord {
        CoachEditRecord(
            id: UUID(),
            appliedAt: appliedAt,
            routineId: UUID(),
            routineName: routineName,
            baseContentHash: "c1-0000000000000000",
            appliedFromContentHash: "c1-0000000000000000",
            resultingContentHash: "c1-1111111111111111",
            rationale: "Synthetic entry.",
            diffs: [],
            previousSections: [],
            previousName: routineName,
            provenance: nil,
            outcome: .applied,
            restoredAt: nil
        )
    }
}
