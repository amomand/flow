import XCTest
@testable import Flow

final class CoachPatchInboxTests: XCTestCase {
    private var createdDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in createdDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        createdDirectories = []
        try super.tearDownWithError()
    }

    // MARK: - Durability

    func testEnqueuedPatchSurvivesReload() throws {
        let fileURL = try makeInboxFileURL()
        let inbox = CoachPatchInbox(fileURL: fileURL)

        guard case .added(let patch) = inbox.enqueue(
            rawJSON: "{\"routineId\":\"x\"}",
            source: .deepLink,
            assistantProvider: "claude"
        ) else {
            return XCTFail("Expected patch to be added")
        }

        let reloaded = CoachPatchInbox(fileURL: fileURL)
        XCTAssertEqual(reloaded.pending.count, 1)
        XCTAssertEqual(reloaded.pending[0].id, patch.id)
        XCTAssertEqual(reloaded.pending[0].source, .deepLink)
        XCTAssertEqual(reloaded.pending[0].assistantProvider, "claude")
        XCTAssertEqual(reloaded.pending[0].status, .pending)
    }

    func testResolvedStatusSurvivesReloadAndLeavesPending() throws {
        let fileURL = try makeInboxFileURL()
        let inbox = CoachPatchInbox(fileURL: fileURL)
        guard case .added(let applied) = inbox.enqueue(rawJSON: "{\"a\":1}", source: .paste),
              case .added(let rejected) = inbox.enqueue(rawJSON: "{\"b\":2}", source: .file) else {
            return XCTFail("Expected patches to be added")
        }

        inbox.markApplied(applied.id)
        inbox.markRejected(rejected.id)

        let reloaded = CoachPatchInbox(fileURL: fileURL)
        XCTAssertTrue(reloaded.pending.isEmpty)
        XCTAssertEqual(reloaded.resolved.count, 2)
        XCTAssertEqual(reloaded.resolved.first(where: { $0.id == applied.id })?.status, .applied)
        XCTAssertEqual(reloaded.resolved.first(where: { $0.id == rejected.id })?.status, .rejected)
        XCTAssertNotNil(reloaded.resolved.first?.resolvedAt)
    }

    func testClearResolvedKeepsPendingPatches() throws {
        let inbox = CoachPatchInbox(fileURL: try makeInboxFileURL())
        guard case .added(let done) = inbox.enqueue(rawJSON: "{\"a\":1}", source: .paste),
              case .added(let open) = inbox.enqueue(rawJSON: "{\"b\":2}", source: .paste) else {
            return XCTFail("Expected patches to be added")
        }
        inbox.markApplied(done.id)

        inbox.clearResolved()

        XCTAssertTrue(inbox.resolved.isEmpty)
        XCTAssertEqual(inbox.pending.map(\.id), [open.id])
    }

    func testRemoveDeletesPatch() throws {
        let inbox = CoachPatchInbox(fileURL: try makeInboxFileURL())
        guard case .added(let patch) = inbox.enqueue(rawJSON: "{\"a\":1}", source: .paste) else {
            return XCTFail("Expected patch to be added")
        }

        inbox.remove(patch.id)

        XCTAssertTrue(inbox.patches.isEmpty)
    }

    func testCorruptInboxFileStartsEmptyAndPreservesBackup() throws {
        let fileURL = try makeInboxFileURL()
        try "not json".write(to: fileURL, atomically: true, encoding: .utf8)

        let inbox = CoachPatchInbox(fileURL: fileURL)

        XCTAssertTrue(inbox.patches.isEmpty)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(siblings.contains { $0.lastPathComponent.hasPrefix("coach-inbox.corrupt-") })
    }

    // MARK: - Enqueue rules

    func testEnqueueDeduplicatesIdenticalPendingPatch() throws {
        let inbox = CoachPatchInbox(fileURL: try makeInboxFileURL())
        let json = "{\"routineId\":\"x\",\"operations\":[]}"
        guard case .added(let first) = inbox.enqueue(rawJSON: json, source: .paste) else {
            return XCTFail("Expected first enqueue to add")
        }

        // Same payload again, fenced the way an assistant would paste it.
        let outcome = inbox.enqueue(rawJSON: "```json\n\(json)\n```", source: .deepLink)

        guard case .duplicate(let existing) = outcome else {
            return XCTFail("Expected duplicate, got \(outcome)")
        }
        XCTAssertEqual(existing.id, first.id)
        XCTAssertEqual(inbox.pending.count, 1)
    }

    func testEnqueueRejectsEmptyAndOversizedPayloads() throws {
        let inbox = CoachPatchInbox(fileURL: try makeInboxFileURL())

        guard case .rejected = inbox.enqueue(rawJSON: "   \n", source: .paste) else {
            return XCTFail("Expected empty payload rejection")
        }
        let huge = String(repeating: "x", count: CoachPatchInbox.maxPatchBytes + 1)
        guard case .rejected = inbox.enqueue(rawJSON: huge, source: .paste) else {
            return XCTFail("Expected oversized payload rejection")
        }
        XCTAssertTrue(inbox.patches.isEmpty)
    }

    // MARK: - Deep link parsing

    func testParseOpenCoachLink() throws {
        let url = try XCTUnwrap(URL(string: "flow://coach"))
        XCTAssertEqual(FlowCoachDeepLink.parse(url), .success(.openCoach))
    }

    func testParsePatchLinkWithBase64URLPayload() throws {
        let json = "{\"rationale\":\"tune >> subject?\"}"
        let encoded = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let url = try XCTUnwrap(URL(string: "flow://coach/patch?d=\(encoded)&provider=claude"))

        XCTAssertEqual(
            FlowCoachDeepLink.parse(url),
            .success(.importPatch(json: json, provider: "claude"))
        )
    }

    func testParsePatchLinkWithPercentEncodedJSONPayload() throws {
        let json = "{\"routineId\":\"abc\",\"operations\":[{\"kind\":\"removeExercise\"}]}"
        var components = try XCTUnwrap(URLComponents(string: "flow://coach/patch"))
        components.queryItems = [URLQueryItem(name: "json", value: json)]
        let url = try XCTUnwrap(components.url)

        XCTAssertEqual(
            FlowCoachDeepLink.parse(url),
            .success(.importPatch(json: json, provider: nil))
        )
    }

    func testParseRejectsBadLinks() throws {
        XCTAssertEqual(
            FlowCoachDeepLink.parse(try XCTUnwrap(URL(string: "flow://coach/patch"))),
            .failure(.missingPayload)
        )
        XCTAssertEqual(
            FlowCoachDeepLink.parse(try XCTUnwrap(URL(string: "flow://coach/patch?d=%20%20"))),
            .failure(.undecodablePayload)
        )
        XCTAssertEqual(
            FlowCoachDeepLink.parse(try XCTUnwrap(URL(string: "flow://coach/settings"))),
            .failure(.unknownRoute("settings"))
        )
        XCTAssertEqual(
            FlowCoachDeepLink.parse(try XCTUnwrap(URL(string: "https://example.com/coach"))),
            .failure(.notCoachURL)
        )
        XCTAssertEqual(
            FlowCoachDeepLink.parse(try XCTUnwrap(URL(string: "flow://runs"))),
            .failure(.notCoachURL)
        )
    }

    // MARK: - Incoming URL handling

    func testHandleIncomingPatchLinkEnqueuesAndPresents() throws {
        let inbox = CoachPatchInbox(fileURL: try makeInboxFileURL())
        let json = "{\"routineId\":\"abc\"}"
        var components = try XCTUnwrap(URLComponents(string: "flow://coach/patch"))
        components.queryItems = [
            URLQueryItem(name: "json", value: json),
            URLQueryItem(name: "provider", value: "chatgpt"),
        ]

        inbox.handleIncomingURL(try XCTUnwrap(components.url))

        XCTAssertEqual(inbox.pending.count, 1)
        XCTAssertEqual(inbox.pending[0].rawJSON, json)
        XCTAssertEqual(inbox.pending[0].source, .deepLink)
        XCTAssertEqual(inbox.pending[0].assistantProvider, "chatgpt")
        XCTAssertTrue(inbox.presentCoach)
        XCTAssertNotNil(inbox.notice)
    }

    func testHandleIncomingBrokenCoachLinkPresentsWithNotice() throws {
        let inbox = CoachPatchInbox(fileURL: try makeInboxFileURL())

        inbox.handleIncomingURL(try XCTUnwrap(URL(string: "flow://coach/patch")))

        XCTAssertTrue(inbox.pending.isEmpty)
        XCTAssertTrue(inbox.presentCoach)
        XCTAssertNotNil(inbox.notice)
    }

    func testHandleIncomingUnrelatedURLIsIgnored() throws {
        let inbox = CoachPatchInbox(fileURL: try makeInboxFileURL())

        inbox.handleIncomingURL(try XCTUnwrap(URL(string: "flow://runs")))

        XCTAssertTrue(inbox.pending.isEmpty)
        XCTAssertFalse(inbox.presentCoach)
        XCTAssertNil(inbox.notice)
    }

    func testHandleIncomingFileURLIngestsPatchFile() throws {
        let fileURL = try makeInboxFileURL()
        let inbox = CoachPatchInbox(fileURL: fileURL)
        let json = "{\"routineId\":\"abc\",\"operations\":[]}"
        let patchFile = fileURL.deletingLastPathComponent().appendingPathComponent("patch.json")
        try json.write(to: patchFile, atomically: true, encoding: .utf8)

        inbox.handleIncomingURL(patchFile)

        XCTAssertEqual(inbox.pending.count, 1)
        XCTAssertEqual(inbox.pending[0].rawJSON, json)
        XCTAssertEqual(inbox.pending[0].source, .file)
        XCTAssertTrue(inbox.presentCoach)
    }

    // MARK: - Readiness summaries

    func testSummaryClassifiesReadyRebaseConflictAndInvalid() throws {
        let inbox = CoachPatchInbox(fileURL: try makeInboxFileURL())
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
        let data = try FlowRoutineExchange.encoder().encode(patch)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        guard case .added(let pending) = inbox.enqueue(rawJSON: json, source: .paste) else {
            return XCTFail("Expected patch to be added")
        }

        let ready = inbox.summary(for: pending, routines: [routine])
        XCTAssertEqual(ready.readiness, .ready)
        XCTAssertEqual(ready.routineName, "Coach")
        XCTAssertEqual(ready.operationCount, 1)

        // Unrelated content change: stale hash, matching expected value.
        routine.sections[0].exercises[0].sets = 4
        XCTAssertEqual(inbox.summary(for: pending, routines: [routine]).readiness, .rebase)

        // Conflicting change: the patched value itself moved.
        routine.sections[0].exercises[0].reps = 9
        guard case .conflict = inbox.summary(for: pending, routines: [routine]).readiness else {
            return XCTFail("Expected conflict readiness")
        }

        guard case .added(let garbage) = inbox.enqueue(rawJSON: "{\"nope\": true}", source: .paste) else {
            return XCTFail("Expected garbage patch to be added")
        }
        guard case .invalid = inbox.summary(for: garbage, routines: [routine]).readiness else {
            return XCTFail("Expected invalid readiness")
        }
    }

    // MARK: - Helpers

    private func makeInboxFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoachPatchInboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)
        return directory.appendingPathComponent("coach-inbox.json")
    }
}
