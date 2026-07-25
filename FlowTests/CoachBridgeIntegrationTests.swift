import XCTest
@testable import Flow

/// End-to-end coach loop against a real running bridge Worker.
///
/// Skipped unless a config file exists at
/// `/private/tmp/flow-coach-integration.json`, so the normal suite stays
/// hermetic and offline. To run it:
///
/// ```
/// cd bridge-worker && npx wrangler dev --port 8787
/// cat > /private/tmp/flow-coach-integration.json <<'JSON'
/// { "baseURL": "http://127.0.0.1:8787",
///   "deviceSecret": "…",
///   "mcpAccessToken": "…" }
/// JSON
/// xcodebuild test -project Flow.xcodeproj -scheme Flow \
///   -destination 'platform=iOS Simulator,name=iPhone 17' \
///   -only-testing:FlowTests/CoachBridgeIntegrationTests
/// ```
///
/// A file is used rather than the environment because `TEST_RUNNER_*`
/// variables do not reach a unit-test bundle hosted in the app.
///
/// Unlike the stubbed tests, this exercises the real HTTP stack, the real
/// Durable Object, and the MCP edge the coach actually talks through.
@MainActor
final class CoachBridgeIntegrationTests: XCTestCase {
    private var createdDirectories: [URL] = []
    private var baseURL = ""
    private var deviceSecret = ""
    private var mcpAccessToken = ""

    private static let configPath = "/private/tmp/flow-coach-integration.json"

    override func setUpWithError() throws {
        guard let data = FileManager.default.contents(atPath: Self.configPath),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw XCTSkip("Write \(Self.configPath) to run the live bridge loop.")
        }
        baseURL = config["baseURL"] ?? ""
        deviceSecret = config["deviceSecret"] ?? ""
        mcpAccessToken = config["mcpAccessToken"] ?? ""
        try XCTSkipIf(baseURL.isEmpty, "baseURL is required in \(Self.configPath).")
        try XCTSkipIf(deviceSecret.isEmpty, "deviceSecret is required in \(Self.configPath).")
        try XCTSkipIf(mcpAccessToken.isEmpty, "mcpAccessToken is required in \(Self.configPath).")
    }

    override func tearDownWithError() throws {
        for url in createdDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        createdDirectories = []
        try super.tearDownWithError()
    }

    func testFullCoachLoopAgainstRunningBridge() async throws {
        let inbox = CoachPatchInbox(fileURL: try makeFileURL("coach-inbox.json"))
        let pairingStore = CoachBridgePairingStore(vault: InMemoryBridgeVault())
        // The real probe runs here: pairing against the running bridge is
        // itself part of what this test proves (#58).
        guard case .success = await pairingStore.pair(
            label: "Local bridge",
            endpointText: baseURL,
            credential: deviceSecret
        ) else {
            return XCTFail("Could not pair with the local bridge")
        }
        let sync = CoachBridgeSync(
            inbox: inbox,
            pairingStore: pairingStore,
            transport: URLSessionBridgeTransport(),
            fileURL: try makeFileURL("coach-bridge-state.json")
        )
        // Start from an empty mailbox so the assertions below are about this run.
        _ = await sync.deleteAllRemoteData()
        sync.approveSharing()

        // 1. Flow uploads a snapshot of a real routine.
        let exerciseId = UUID()
        let routine = Routine(
            name: "Integration Push",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(id: exerciseId, name: "Overhead Press", sets: 3, reps: 8)
                ])
            ]
        )
        let store = RoutineStore(
            fileURL: try makeFileURL("routines.json"),
            defaults: makeIsolatedDefaults(),
            editHistory: CoachEditHistoryStore(fileURL: try makeFileURL("coach-history.json"))
        )
        store.routines = [routine]
        XCTAssertNoThrow(try store.save().get())

        let uploaded = await sync.syncToCoach(
            routines: store.routines,
            strengthWorkouts: [],
            cardioWorkouts: []
        )
        guard case .success(let receipt) = uploaded else {
            return XCTFail("Snapshot upload failed: \(uploaded)")
        }

        // 2. Act as the coach: read the snapshot back through the MCP edge and
        //    propose an edit against the exact hash Flow published.
        let context = try await callTool("get_flow_coach_context", arguments: [:])
        let contextId = ((context["structuredContent"] as? [String: Any])?["contextId"]) as? String
        XCTAssertEqual(contextId, receipt.contextId.uuidString, "the coach must read the snapshot Flow just sent")

        let routineSummaries = (context["structuredContent"] as? [String: Any])?["routines"] as? [[String: Any]]
        let summary = try XCTUnwrap(routineSummaries?.first)
        let contentHash = try XCTUnwrap(summary["contentHash"] as? String)
        XCTAssertEqual(contentHash, FlowRoutineRevision.contentHash(for: routine))

        let proposal = try await callTool("create_pending_routine_patch", arguments: [
            "contextId": receipt.contextId.uuidString,
            "idempotencyKey": "integration-\(receipt.contextId.uuidString)",
            "patch": [
                "schemaVersion": 2,
                "routineId": routine.id.uuidString,
                "baseContentHash": contentHash,
                "rationale": "Integration test: add a set to the press.",
                "operations": [[
                    "kind": "replaceExerciseSets",
                    "exerciseId": exerciseId.uuidString,
                    "expectedIntValue": 3,
                    "newIntValue": 4,
                ]],
            ],
        ])
        let stored = try XCTUnwrap(proposal["structuredContent"] as? [String: Any])
        let bridgePatchId = try XCTUnwrap((stored["patch"] as? [String: Any])?["patchId"] as? String)
        XCTAssertEqual((stored["patch"] as? [String: Any])?["provenance"] as? String, "claude-mcp")

        // 3. Flow pulls the draft into its existing durable inbox.
        let pulled = await sync.pullPendingPatches()
        XCTAssertEqual(pulled, .success(1))
        let pending = try XCTUnwrap(inbox.pending.first)
        XCTAssertEqual(pending.source, .bridge)
        XCTAssertEqual(pending.remoteProvenance?.bridgePatchId, bridgePatchId)
        XCTAssertEqual(pending.assistantProvider, "claude-mcp")
        XCTAssertEqual(
            inbox.summary(for: pending, routines: store.routines).readiness,
            .ready,
            "a draft composed against the published hash should preview cleanly"
        )

        // 4. Flow, not the bridge, applies it.
        let preview = try store.previewRoutinePatchJSON(pending.rawJSON).get()
        let applied = try store.applyRoutinePatchPreview(
            preview,
            provenance: CoachEditProvenance(
                sourcePatchId: pending.id,
                bridgePatchId: bridgePatchId,
                contextId: pending.remoteProvenance?.contextId,
                assistantProvider: pending.assistantProvider,
                source: .bridge
            )
        ).get()
        XCTAssertEqual(applied.sections[0].exercises[0].sets, 4)
        XCTAssertTrue(inbox.markApplied(pending.id))

        // 5. Only now is the mailbox told, and the record leaves the pending set.
        await sync.recordDecision(bridgePatchId: bridgePatchId, status: .applied)
        XCTAssertTrue(sync.pendingAcknowledgements.isEmpty, "the acknowledgement should have been delivered")

        let afterApply = await sync.pullPendingPatches()
        XCTAssertEqual(afterApply, .success(0), "an applied draft must not be offered again")
        XCTAssertEqual(inbox.pending.count, 0)

        // 6. Deleting the snapshot leaves the local audit trail intact.
        let deleted = await sync.deleteSnapshot()
        if case .failure(let error) = deleted {
            XCTFail("Snapshot delete failed: \(error.localizedDescription)")
        }
        XCTAssertNil(sync.lastSnapshot)
        XCTAssertEqual(store.editHistory?.records.count, 1)
    }

    // MARK: - MCP helper

    /// Calls one MCP tool the way Claude's connector would: a single JSON-RPC
    /// POST to /mcp carrying the OAuth access token.
    private func callTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ]
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(baseURL)/mcp")))
        request.httpMethod = "POST"
        request.setValue("Bearer \(mcpAccessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 200, "MCP \(name) returned \(status): \(String(data: data, encoding: .utf8) ?? "")")
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let error = decoded["error"] {
            XCTFail("MCP \(name) errored: \(error)")
        }
        let result = try XCTUnwrap(decoded["result"] as? [String: Any])
        if let isError = result["isError"] as? Bool, isError {
            XCTFail("MCP \(name) tool error: \(result["content"] ?? "")")
        }
        return result
    }

    // MARK: - Fixtures

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "CoachBridgeIntegrationTests-\(UUID().uuidString)")!
        return suite
    }

    private func makeFileURL(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoachBridgeIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)
        return directory.appendingPathComponent(name)
    }
}
