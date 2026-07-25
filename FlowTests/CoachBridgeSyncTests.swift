import XCTest
@testable import Flow

/// Scripted device-edge transport. Replies are queued per `"METHOD /path"`
/// key; a queued status of `-1` simulates a network failure so retry
/// behaviour can be exercised without a server.
private actor StubBridgeTransport: CoachBridgeTransport {
    struct Recorded: Equatable {
        let method: String
        let path: String
        let bodyText: String?
        let authorization: String?
    }

    private struct Reply {
        let status: Int
        let json: String
    }

    private var replies: [String: [Reply]] = [:]
    private var recorded: [Recorded] = []

    func stub(_ key: String, status: Int, json: String = "{}") {
        replies[key, default: []].append(Reply(status: status, json: json))
    }

    func stubFailure(_ key: String) {
        replies[key, default: []].append(Reply(status: -1, json: ""))
    }

    func requests() -> [Recorded] { recorded }

    func requestCount(_ key: String) -> Int {
        recorded.filter { "\($0.method) \($0.path)" == key }.count
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        recorded.append(
            Recorded(
                method: method,
                path: path,
                bodyText: request.httpBody.flatMap { String(data: $0, encoding: .utf8) },
                authorization: request.value(forHTTPHeaderField: "Authorization")
            )
        )
        let key = "\(method) \(path)"
        let reply = replies[key]?.isEmpty == false ? replies[key]!.removeFirst() : Reply(status: 200, json: "{}")
        if reply.status == -1 {
            throw CoachBridgeError.transport("the network is unavailable")
        }
        // A real mailbox echoes back the identity it stored. `$CONTEXT_ID$`
        // stands in for "whatever Flow just sent", so identity verification is
        // exercised rather than bypassed.
        var json = reply.json
        if json.contains("$CONTEXT_ID$") {
            json = json.replacingOccurrences(of: "$CONTEXT_ID$", with: Self.contextId(in: request.httpBody) ?? "")
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(json.utf8), response)
    }

    private static func contextId(in body: Data?) -> String? {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return object["contextId"] as? String
    }
}

@MainActor
final class CoachBridgeSyncTests: XCTestCase {
    private var createdDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in createdDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        createdDirectories = []
        try super.tearDownWithError()
    }

    // MARK: - Pairing

    func testPairingSurvivesReloadAndKeepsCredentialOutOfDisplayFields() throws {
        let vault = InMemoryBridgeVault()
        let store = CoachBridgePairingStore(vault: vault)

        guard case .success(let pairing) = store.pair(
            label: "Alex's mailbox",
            endpointText: "https://flow-coach-bridge-primary.example.workers.dev",
            credential: "device-secret-one"
        ) else {
            return XCTFail("Expected pairing to succeed")
        }
        XCTAssertEqual(pairing.label, "Alex's mailbox")
        XCTAssertEqual(pairing.endpointDescription, "flow-coach-bridge-primary.example.workers.dev")

        let reloaded = CoachBridgePairingStore(vault: vault)
        XCTAssertTrue(reloaded.isPaired)
        XCTAssertEqual(reloaded.pairing?.label, "Alex's mailbox")
        XCTAssertEqual(reloaded.credential(), "device-secret-one")
    }

    func testPairingRejectsInsecureAndMalformedEndpoints() {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault())

        XCTAssertEqual(
            store.pair(label: "x", endpointText: "http://coach.example.com", credential: "c"),
            .failure(.insecureEndpoint)
        )
        XCTAssertEqual(
            store.pair(label: "x", endpointText: "not a url at all", credential: "c"),
            .failure(.invalidEndpoint)
        )
        XCTAssertEqual(
            store.pair(label: "  ", endpointText: "https://coach.example.com", credential: "c"),
            .failure(.emptyLabel)
        )
        XCTAssertEqual(
            store.pair(label: "x", endpointText: "https://coach.example.com", credential: "   "),
            .failure(.emptyCredential)
        )
        XCTAssertFalse(store.isPaired)
    }

    func testLoopbackHTTPIsAllowedForLocalVerification() {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault())
        guard case .success(let pairing) = store.pair(
            label: "local",
            endpointText: "http://127.0.0.1:8787/",
            credential: "c"
        ) else {
            return XCTFail("Expected loopback pairing to succeed")
        }
        // The trailing slash is normalised away so path joining stays correct.
        XCTAssertEqual(pairing.endpoint.absoluteString, "http://127.0.0.1:8787")
    }

    func testBareHostGainsHTTPSScheme() {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault())
        guard case .success(let pairing) = store.pair(
            label: "x",
            endpointText: "coach.example.com",
            credential: "c"
        ) else {
            return XCTFail("Expected pairing to succeed")
        }
        XCTAssertEqual(pairing.endpoint.scheme, "https")
    }

    func testRotationKeepsEndpointAndReplacesCredential() {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault())
        store.pair(label: "x", endpointText: "https://coach.example.com", credential: "old")

        guard case .success = store.rotateCredential("new") else {
            return XCTFail("Expected rotation to succeed")
        }
        XCTAssertEqual(store.credential(), "new")
        XCTAssertEqual(store.pairing?.endpoint.absoluteString, "https://coach.example.com")
    }

    func testSignOutClearsPairingWithoutTouchingLocalData() throws {
        let inbox = CoachPatchInbox(fileURL: try makeFileURL("coach-inbox.json"))
        inbox.enqueue(rawJSON: "{\"a\":1}", source: .paste)
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault())
        store.pair(label: "x", endpointText: "https://coach.example.com", credential: "c")
        let sync = try makeSync(inbox: inbox, pairingStore: store, transport: StubBridgeTransport())

        XCTAssertTrue(sync.signOut())

        XCTAssertFalse(sync.isPaired)
        XCTAssertEqual(inbox.pending.count, 1, "signing out must not delete local inbox records")
    }

    func testSwitchDetectionOnlyFlagsADifferentEndpoint() {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault())
        store.pair(label: "x", endpointText: "https://a.example.com", credential: "c")

        XCTAssertFalse(store.isSwitch(to: "https://a.example.com/"))
        XCTAssertTrue(store.isSwitch(to: "https://b.example.com"))
    }

    // MARK: - Sharing approval

    func testFirstSyncRequiresExplicitSharingApproval() async throws {
        let transport = StubBridgeTransport()
        let sync = try makeSync(transport: transport)

        XCTAssertTrue(sync.requiresSharingApproval)
        let result = await sync.syncToCoach(routines: [], strengthWorkouts: [], cardioWorkouts: [])

        XCTAssertEqual(result, .failure(.sharingNotApproved))
        let count = await transport.requests().count
        XCTAssertEqual(count, 0, "nothing may leave the device before the categories are approved")
    }

    func testChangingSharingSelectionRevokesApproval() throws {
        let sync = try makeSync()
        sync.approveSharing()
        XCTAssertFalse(sync.requiresSharingApproval)

        sync.updateSharingProfile(FlowCoachSharingProfile(dataTiers: [.routines, .strengthHistory, .healthMetrics]))

        XCTAssertTrue(sync.requiresSharingApproval, "a widened selection must be re-approved")
    }

    func testDefaultSharingProfileIsRoutinesAndStrengthHistoryOnly() throws {
        let sync = try makeSync()
        XCTAssertEqual(sync.sharingProfile.dataTiers, [.routines, .strengthHistory])
        XCTAssertFalse(sync.sharingProfile.includes(.cardioHistory))
        XCTAssertFalse(sync.sharingProfile.includes(.healthMetrics))
    }

    func testSharingSelectionAndApprovalSurviveReload() throws {
        let stateURL = try makeFileURL("coach-bridge-state.json")
        let inboxURL = try makeFileURL("coach-inbox.json")
        let profile = FlowCoachSharingProfile(dataTiers: [.routines, .strengthHistory, .cardioHistory])
        do {
            let sync = try makeSync(inboxURL: inboxURL, stateURL: stateURL)
            sync.updateSharingProfile(profile)
            sync.approveSharing()
        }

        let reloaded = try makeSync(inboxURL: inboxURL, stateURL: stateURL)
        XCTAssertEqual(reloaded.sharingProfile.dataTiers, profile.dataTiers)
        XCTAssertFalse(reloaded.requiresSharingApproval)
    }

    // MARK: - Snapshot upload

    func testSyncUploadsEnvelopeAndRecordsReceipt() async throws {
        let transport = StubBridgeTransport()
        let sync = try makeSync(transport: transport)
        sync.approveSharing()
        let routine = Routine(name: "Push", sections: [])

        // The bridge echoes the identity Flow sent.
        let envelopeId = await captureUploadedContextId(transport: transport, sync: sync, routines: [routine])

        XCTAssertEqual(sync.lastSnapshot?.contextId.uuidString, envelopeId)
        XCTAssertEqual(sync.lastSnapshot?.dataTiers, [.routines, .strengthHistory])
        let recorded = await transport.requests()
        XCTAssertEqual(recorded.first?.method, "PUT")
        XCTAssertEqual(recorded.first?.path, "/device/snapshots")
        XCTAssertEqual(recorded.first?.authorization, "Bearer device-secret")
    }

    func testSyncRejectsAMailboxThatStoredADifferentIdentity() async throws {
        let transport = StubBridgeTransport()
        await transport.stub(
            "PUT /device/snapshots",
            status: 201,
            json: "{\"stored\":true,\"contextId\":\"11111111-1111-1111-1111-111111111111\"}"
        )
        let sync = try makeSync(transport: transport)
        sync.approveSharing()

        let result = await sync.syncToCoach(routines: [], strengthWorkouts: [], cardioWorkouts: [])

        XCTAssertEqual(result, .failure(.identityMismatch))
        XCTAssertNil(sync.lastSnapshot, "an unverified upload must not be recorded as synced")
    }

    func testInvalidCredentialIsReportedAsRotatable() async throws {
        let transport = StubBridgeTransport()
        await transport.stub("PUT /device/snapshots", status: 401, json: "{\"error\":\"Invalid or missing credential.\"}")
        let sync = try makeSync(transport: transport)
        sync.approveSharing()

        let result = await sync.syncToCoach(routines: [], strengthWorkouts: [], cardioWorkouts: [])

        XCTAssertEqual(result, .failure(.invalidCredential))
        XCTAssertEqual(sync.lastSyncError, CoachBridgeError.invalidCredential.errorDescription)
    }

    func testUploadedEnvelopeExcludesUnselectedCategories() async throws {
        let transport = StubBridgeTransport()
        let sync = try makeSync(transport: transport)
        sync.approveSharing()
        await captureUploadedContextId(transport: transport, sync: sync, routines: [Routine(name: "Push", sections: [])])

        let body = await transport.requests().first?.bodyText ?? ""
        XCTAssertTrue(body.contains("\"routines\""))
        XCTAssertTrue(body.contains("\"strengthHistory\""))
        XCTAssertFalse(body.contains("\"cardioHistory\""), "cardio is a separate opt-in")
        XCTAssertFalse(body.contains("\"healthMetrics\""), "HealthKit-derived metrics are a separate opt-in")
        XCTAssertFalse(body.contains("appleWatchMetrics"))
    }

    // MARK: - Snapshot deletion

    func testDeleteSnapshotTargetsTheUploadedContextAndClearsTheReceipt() async throws {
        let transport = StubBridgeTransport()
        let sync = try makeSync(transport: transport)
        sync.approveSharing()
        let contextId = await captureUploadedContextId(transport: transport, sync: sync, routines: [])
        await transport.stub("DELETE /device/snapshots/\(contextId)", status: 200, json: "{\"deleted\":true}")

        let result = await sync.deleteSnapshot()

        assertSucceeded(result)
        XCTAssertNil(sync.lastSnapshot)
        let deletes = await transport.requestCount("DELETE /device/snapshots/\(contextId)")
        XCTAssertEqual(deletes, 1)
    }

    func testDeletingAnAlreadyGoneSnapshotStillClearsTheLocalRecord() async throws {
        let transport = StubBridgeTransport()
        let sync = try makeSync(transport: transport)
        sync.approveSharing()
        let contextId = await captureUploadedContextId(transport: transport, sync: sync, routines: [])
        await transport.stub("DELETE /device/snapshots/\(contextId)", status: 410, json: "{\"error\":\"expired\"}")

        let result = await sync.deleteSnapshot()

        assertSucceeded(result)
        XCTAssertNil(sync.lastSnapshot)
    }

    func testDeleteAllRemoteDataClearsReceiptAndOwedAcknowledgements() async throws {
        let transport = StubBridgeTransport()
        let sync = try makeSync(transport: transport)
        sync.approveSharing()
        _ = await captureUploadedContextId(transport: transport, sync: sync, routines: [])
        await transport.stubFailure("POST /device/pending-patches/p1/ack")
        await sync.recordDecision(bridgePatchId: "p1", status: .applied)
        XCTAssertEqual(sync.pendingAcknowledgements.count, 1)

        let result = await sync.deleteAllRemoteData()

        assertSucceeded(result)
        XCTAssertNil(sync.lastSnapshot)
        XCTAssertTrue(sync.pendingAcknowledgements.isEmpty)
    }

    // MARK: - Pull

    func testPullLandsPatchInInboxOnceAcrossRepeatedPulls() async throws {
        let transport = StubBridgeTransport()
        let inbox = CoachPatchInbox(fileURL: try makeFileURL("coach-inbox.json"))
        let sync = try makeSync(inbox: inbox, transport: transport)
        let body = Self.pullBody(bridgePatchId: "bridge-1", contextId: "ctx-1")
        await transport.stub("GET /device/pending-patches", status: 200, json: body)
        await transport.stub("GET /device/pending-patches", status: 200, json: body)

        let first = await sync.pullPendingPatches()
        let second = await sync.pullPendingPatches()

        XCTAssertEqual(first, .success(1))
        XCTAssertEqual(second, .success(0), "a repeated pull adds nothing new")
        XCTAssertEqual(inbox.pending.count, 1)
        let stored = inbox.pending.first
        XCTAssertEqual(stored?.source, .bridge)
        XCTAssertEqual(stored?.remoteProvenance?.bridgePatchId, "bridge-1")
        XCTAssertEqual(stored?.remoteProvenance?.contextId, "ctx-1")
        XCTAssertEqual(stored?.assistantProvider, "claude-mcp")
    }

    func testPullAcknowledgesOnlyAfterTheInboxWriteSucceeds() async throws {
        let transport = StubBridgeTransport()
        // An inbox whose directory does not exist cannot persist anything.
        let unwritable = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoachBridgeSyncTests-missing-\(UUID().uuidString)", isDirectory: true)
        createdDirectories.append(unwritable)
        let inbox = CoachPatchInbox(fileURL: unwritable.appendingPathComponent("coach-inbox.json"))
        let sync = try makeSync(inbox: inbox, transport: transport)
        await transport.stub(
            "GET /device/pending-patches",
            status: 200,
            json: Self.pullBody(bridgePatchId: "bridge-1", contextId: "ctx-1")
        )

        let result = await sync.pullPendingPatches()

        guard case .failure = result else {
            return XCTFail("Expected the failed local write to surface")
        }
        XCTAssertTrue(inbox.patches.isEmpty)
        let acks = await transport.requestCount("POST /device/pending-patches/bridge-1/ack")
        XCTAssertEqual(acks, 0, "the bridge must keep offering a draft Flow could not store")
        XCTAssertTrue(sync.pendingAcknowledgements.isEmpty)
    }

    func testPullAcknowledgesPulledAfterStoring() async throws {
        let transport = StubBridgeTransport()
        let sync = try makeSync(transport: transport)
        await transport.stub(
            "GET /device/pending-patches",
            status: 200,
            json: Self.pullBody(bridgePatchId: "bridge-1", contextId: "ctx-1")
        )

        _ = await sync.pullPendingPatches()

        let recorded = await transport.requests()
        let ack = recorded.first { $0.path == "/device/pending-patches/bridge-1/ack" }
        XCTAssertNotNil(ack)
        XCTAssertEqual(ack?.bodyText, "{\"status\":\"pulled\"}")
        XCTAssertTrue(sync.pendingAcknowledgements.isEmpty, "a delivered acknowledgement is not kept")
    }

    func testMalformedPullRowsAreSkippedRatherThanCrashing() {
        let payload: [String: Any] = [
            "patches": [
                ["patchId": "ok", "contextId": "c", "patch": ["schemaVersion": 2]],
                ["contextId": "c", "patch": ["schemaVersion": 2]],
                ["patchId": "no-patch", "contextId": "c"],
            ]
        ]

        let decoded = CoachBridgeSync.decodePulledPatches(from: payload)

        XCTAssertEqual(decoded.map(\.bridgePatchId), ["ok"])
    }

    // MARK: - Acknowledgement retries

    func testRetryableAcknowledgementFailureIsKeptAndSurvivesReload() async throws {
        let transport = StubBridgeTransport()
        let stateURL = try makeFileURL("coach-bridge-state.json")
        let inboxURL = try makeFileURL("coach-inbox.json")
        await transport.stubFailure("POST /device/pending-patches/bridge-1/ack")
        do {
            let sync = try makeSync(inboxURL: inboxURL, stateURL: stateURL, transport: transport)
            await sync.recordDecision(bridgePatchId: "bridge-1", status: .applied)
            XCTAssertEqual(sync.pendingAcknowledgements.count, 1)
            XCTAssertEqual(sync.pendingAcknowledgements.first?.attempts, 1)
        }

        let reloaded = try makeSync(inboxURL: inboxURL, stateURL: stateURL, transport: transport)
        XCTAssertEqual(reloaded.pendingAcknowledgements.first?.bridgePatchId, "bridge-1")
        XCTAssertEqual(reloaded.pendingAcknowledgements.first?.status, .applied)
    }

    func testQueuedAcknowledgementIsDeliveredOnALaterFlush() async throws {
        let transport = StubBridgeTransport()
        await transport.stubFailure("POST /device/pending-patches/bridge-1/ack")
        let sync = try makeSync(transport: transport)
        await sync.recordDecision(bridgePatchId: "bridge-1", status: .applied)
        XCTAssertEqual(sync.pendingAcknowledgements.count, 1)

        await transport.stub("POST /device/pending-patches/bridge-1/ack", status: 200, json: "{\"acknowledged\":true}")
        await sync.flushAcknowledgements()

        XCTAssertTrue(sync.pendingAcknowledgements.isEmpty)
    }

    func testTerminalAcknowledgementFailureIsNotRetriedForever() async throws {
        let transport = StubBridgeTransport()
        await transport.stub("POST /device/pending-patches/bridge-1/ack", status: 404, json: "{\"error\":\"Patch was not found.\"}")
        let sync = try makeSync(transport: transport)

        await sync.recordDecision(bridgePatchId: "bridge-1", status: .applied)

        XCTAssertTrue(sync.pendingAcknowledgements.isEmpty)
    }

    func testTerminalDecisionSupersedesAnUndeliveredPulledAcknowledgement() async throws {
        let transport = StubBridgeTransport()
        await transport.stubFailure("POST /device/pending-patches/bridge-1/ack")
        await transport.stubFailure("POST /device/pending-patches/bridge-1/ack")
        let sync = try makeSync(transport: transport)

        await sync.recordDecision(bridgePatchId: "bridge-1", status: .pulled)
        await sync.recordDecision(bridgePatchId: "bridge-1", status: .applied)

        XCTAssertEqual(sync.pendingAcknowledgements.count, 1)
        XCTAssertEqual(sync.pendingAcknowledgements.first?.status, .applied)
    }

    func testAcknowledgementsAreNeverSentToADifferentMailbox() async throws {
        let transport = StubBridgeTransport()
        let vault = InMemoryBridgeVault()
        let pairingStore = CoachBridgePairingStore(vault: vault)
        pairingStore.pair(label: "mine", endpointText: "https://mine.example.com", credential: "mine-secret")
        await transport.stubFailure("POST /device/pending-patches/bridge-1/ack")
        let sync = try makeSync(pairingStore: pairingStore, transport: transport)
        await sync.recordDecision(bridgePatchId: "bridge-1", status: .applied)
        XCTAssertEqual(sync.pendingAcknowledgements.count, 1)

        // Switch to the other person's mailbox.
        pairingStore.pair(label: "theirs", endpointText: "https://theirs.example.com", credential: "their-secret")
        await sync.flushAcknowledgements()

        XCTAssertTrue(sync.actionableAcknowledgements.isEmpty)
        let leaked = await transport.requests().filter { $0.authorization == "Bearer their-secret" }
        XCTAssertTrue(leaked.isEmpty, "no acknowledgement may be delivered with the new mailbox's credential")
    }

    func testSwitchingDiscardsAcknowledgementsAndSnapshotFromTheOldMailbox() async throws {
        let transport = StubBridgeTransport()
        let vault = InMemoryBridgeVault()
        let pairingStore = CoachBridgePairingStore(vault: vault)
        pairingStore.pair(label: "mine", endpointText: "https://mine.example.com", credential: "mine-secret")
        let sync = try makeSync(pairingStore: pairingStore, transport: transport)
        sync.approveSharing()
        _ = await captureUploadedContextId(transport: transport, sync: sync, routines: [])
        await transport.stubFailure("POST /device/pending-patches/bridge-1/ack")
        await sync.recordDecision(bridgePatchId: "bridge-1", status: .applied)
        XCTAssertEqual(sync.acknowledgementsLostBySwitching(), 1)

        pairingStore.pair(label: "theirs", endpointText: "https://theirs.example.com", credential: "their-secret")
        sync.discardAcknowledgements(notMatching: pairingStore.pairing?.endpoint)

        XCTAssertTrue(sync.pendingAcknowledgements.isEmpty)
        XCTAssertNil(sync.lastSnapshot, "the previous mailbox's snapshot record must not follow the switch")
    }

    func testUnpairedSyncMakesNoNetworkCalls() async throws {
        let transport = StubBridgeTransport()
        let sync = try makeSync(pairingStore: CoachBridgePairingStore(vault: InMemoryBridgeVault()), transport: transport)

        let upload = await sync.syncToCoach(routines: [], strengthWorkouts: [], cardioWorkouts: [])
        let pull = await sync.pullPendingPatches()
        await sync.recordDecision(bridgePatchId: "bridge-1", status: .applied)

        XCTAssertEqual(upload, .failure(.notPaired))
        XCTAssertEqual(pull, .failure(.notPaired))
        XCTAssertTrue(sync.pendingAcknowledgements.isEmpty)
        let count = await transport.requests().count
        XCTAssertEqual(count, 0)
    }

    func testExpiredSnapshotIsReportedAsNeedingAFreshSync() async throws {
        let transport = StubBridgeTransport()
        await transport.stub("GET /device/pending-patches", status: 410, json: "{\"error\":\"That coach snapshot expired.\"}")
        let sync = try makeSync(transport: transport)

        let result = await sync.pullPendingPatches()

        XCTAssertEqual(result, .failure(.snapshotGone("That coach snapshot expired.")))
    }

    func testRetryClassificationSeparatesTransientFromTerminal() {
        XCTAssertTrue(CoachBridgeError.transport("offline").isRetryable)
        XCTAssertTrue(CoachBridgeError.rejected(status: 503, detail: nil).isRetryable)
        XCTAssertTrue(CoachBridgeError.rejected(status: 429, detail: nil).isRetryable)
        XCTAssertFalse(CoachBridgeError.rejected(status: 409, detail: nil).isRetryable)
        XCTAssertFalse(CoachBridgeError.invalidCredential.isRetryable)
        XCTAssertFalse(CoachBridgeError.identityMismatch.isRetryable)
    }

    func testSnapshotReceiptKnowsWhenItHasExpired() {
        let receipt = CoachBridgeSnapshotReceipt(
            contextId: UUID(),
            uploadedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 100),
            endpoint: URL(string: "https://coach.example.com")!,
            dataTiers: [.routines]
        )

        XCTAssertFalse(receipt.isExpired(at: Date(timeIntervalSince1970: 50)))
        XCTAssertTrue(receipt.isExpired(at: Date(timeIntervalSince1970: 100)))
    }

    // MARK: - Helpers

    /// Uploads once against a mailbox that echoes back the identity Flow sent,
    /// and returns that contextId.
    @discardableResult
    private func captureUploadedContextId(
        transport: StubBridgeTransport,
        sync: CoachBridgeSync,
        routines: [Routine]
    ) async -> String {
        await transport.stub(
            "PUT /device/snapshots",
            status: 201,
            json: "{\"stored\":true,\"contextId\":\"$CONTEXT_ID$\"}"
        )
        _ = await sync.syncToCoach(routines: routines, strengthWorkouts: [], cardioWorkouts: [])
        return sync.lastSnapshot?.contextId.uuidString ?? ""
    }

    private func assertSucceeded(
        _ result: Result<Void, CoachBridgeError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("Expected success, got \(error.localizedDescription)", file: file, line: line)
        }
    }

    private static func pullBody(bridgePatchId: String, contextId: String) -> String {
        """
        {
          "patches": [
            {
              "cursor": 1,
              "patchId": "\(bridgePatchId)",
              "contextId": "\(contextId)",
              "routineId": "11111111-1111-1111-1111-111111111111",
              "baseContentHash": "c1-0123456789abcdef",
              "status": "pending",
              "provenance": "claude-mcp",
              "rationale": "Add a set.",
              "patch": {
                "schemaVersion": 2,
                "routineId": "11111111-1111-1111-1111-111111111111",
                "baseContentHash": "c1-0123456789abcdef",
                "rationale": "Add a set.",
                "operations": [
                  {
                    "kind": "replaceExerciseSets",
                    "exerciseId": "22222222-2222-2222-2222-222222222222",
                    "expectedIntValue": 3,
                    "newIntValue": 4
                  }
                ]
              }
            }
          ],
          "nextCursor": 1
        }
        """
    }

    private func makeSync(
        inbox: CoachPatchInbox? = nil,
        inboxURL: URL? = nil,
        stateURL: URL? = nil,
        pairingStore: CoachBridgePairingStore? = nil,
        transport: StubBridgeTransport = StubBridgeTransport()
    ) throws -> CoachBridgeSync {
        let resolvedInbox = try inbox ?? CoachPatchInbox(fileURL: inboxURL ?? makeFileURL("coach-inbox.json"))
        let resolvedPairing: CoachBridgePairingStore
        if let pairingStore {
            resolvedPairing = pairingStore
        } else {
            resolvedPairing = CoachBridgePairingStore(vault: InMemoryBridgeVault())
            resolvedPairing.pair(
                label: "Test mailbox",
                endpointText: "https://coach.example.com",
                credential: "device-secret"
            )
        }
        return CoachBridgeSync(
            inbox: resolvedInbox,
            pairingStore: resolvedPairing,
            transport: transport,
            fileURL: try stateURL ?? makeFileURL("coach-bridge-state.json")
        )
    }

    private func makeFileURL(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoachBridgeSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)
        return directory.appendingPathComponent(name)
    }
}
