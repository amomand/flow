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

    /// A device with no connection at all, which is a different thing from a
    /// network that cannot find the mailbox (#58).
    func stubOffline(_ key: String) {
        replies[key, default: []].append(Reply(status: -2, json: ""))
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
        if reply.status == -2 {
            throw URLError(.notConnectedToInternet)
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

/// Scripted pairing probe. Accepts by default, so tests that only care about
/// what happens after pairing read as they did before validation existed.
private actor StubPairingProbe: CoachBridgePairingProbe {
    private var results: [CoachBridgePairingCheck]
    private var seen: [(endpoint: URL, credential: String)] = []

    init(_ results: [CoachBridgePairingCheck] = []) {
        self.results = results
    }

    func checkCount() -> Int { seen.count }

    func lastCredential() -> String? { seen.last?.credential }

    func check(endpoint: URL, credential: String) async -> CoachBridgePairingCheck {
        seen.append((endpoint, credential))
        return results.isEmpty ? .accepted : results.removeFirst()
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

    func testPairingSurvivesReloadAndKeepsCredentialOutOfDisplayFields() async throws {
        let vault = InMemoryBridgeVault()
        let store = CoachBridgePairingStore(vault: vault, probe: StubPairingProbe())

        guard case .success(let pairing) = await store.pair(
            label: "Alex's mailbox",
            endpointText: "https://flow-coach-bridge-primary.example.workers.dev",
            credential: "device-secret-one"
        ) else {
            return XCTFail("Expected pairing to succeed")
        }
        XCTAssertEqual(pairing.label, "Alex's mailbox")
        XCTAssertEqual(pairing.endpointDescription, "flow-coach-bridge-primary.example.workers.dev")

        let reloaded = CoachBridgePairingStore(vault: vault, probe: StubPairingProbe())
        XCTAssertTrue(reloaded.isPaired)
        XCTAssertEqual(reloaded.pairing?.label, "Alex's mailbox")
        XCTAssertEqual(reloaded.credential(), "device-secret-one")
    }

    func testPairingRejectsInsecureAndMalformedEndpoints() async {
        let probe = StubPairingProbe()
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: probe)

        let insecure = await store.pair(label: "x", endpointText: "http://coach.example.com", credential: "c")
        XCTAssertEqual(insecure, .failure(.insecureEndpoint))
        let malformed = await store.pair(label: "x", endpointText: "not a url at all", credential: "c")
        XCTAssertEqual(malformed, .failure(.invalidEndpoint))
        let unnamed = await store.pair(label: "  ", endpointText: "https://coach.example.com", credential: "c")
        XCTAssertEqual(unnamed, .failure(.emptyLabel))
        let uncredentialled = await store.pair(label: "x", endpointText: "https://coach.example.com", credential: "   ")
        XCTAssertEqual(uncredentialled, .failure(.emptyCredential))

        XCTAssertFalse(store.isPaired)
        let checks = await probe.checkCount()
        XCTAssertEqual(checks, 0, "a pairing that cannot be formed must not reach the network")
    }

    func testLoopbackHTTPIsAllowedForLocalVerification() async {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: StubPairingProbe())
        guard case .success(let pairing) = await store.pair(
            label: "local",
            endpointText: "http://127.0.0.1:8787/",
            credential: "c"
        ) else {
            return XCTFail("Expected loopback pairing to succeed")
        }
        // The trailing slash is normalised away so path joining stays correct.
        XCTAssertEqual(pairing.endpoint.absoluteString, "http://127.0.0.1:8787")
    }

    func testBareHostGainsHTTPSScheme() async {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: StubPairingProbe())
        guard case .success(let pairing) = await store.pair(
            label: "x",
            endpointText: "coach.example.com",
            credential: "c"
        ) else {
            return XCTFail("Expected pairing to succeed")
        }
        XCTAssertEqual(pairing.endpoint.scheme, "https")
    }

    func testEndpointIsStoredAsSomethingAPathCanBeAppendedTo() async {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: StubPairingProbe())

        guard case .success(let pairing) = await store.pair(
            label: "x",
            endpointText: "https://coach.example.com/?utm=1#top",
            credential: "c"
        ) else {
            return XCTFail("Expected pairing to succeed")
        }

        // Request paths are appended by string, so a pasted query or fragment
        // would otherwise swallow the path.
        XCTAssertEqual(pairing.endpoint.absoluteString, "https://coach.example.com")
        XCTAssertEqual(
            URL(string: pairing.endpoint.absoluteString + "/device/pending-patches")?.path,
            "/device/pending-patches"
        )
    }

    func testRotationKeepsEndpointAndReplacesCredential() async {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: StubPairingProbe())
        await store.pair(label: "x", endpointText: "https://coach.example.com", credential: "old")

        guard case .success = await store.rotateCredential("new") else {
            return XCTFail("Expected rotation to succeed")
        }
        XCTAssertEqual(store.credential(), "new")
        XCTAssertEqual(store.pairing?.endpoint.absoluteString, "https://coach.example.com")
    }

    func testSignOutClearsPairingWithoutTouchingLocalData() async throws {
        let inbox = CoachPatchInbox(fileURL: try makeFileURL("coach-inbox.json"))
        inbox.enqueue(rawJSON: "{\"a\":1}", source: .paste)
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: StubPairingProbe())
        await store.pair(label: "x", endpointText: "https://coach.example.com", credential: "c")
        let sync = try await makeSync(inbox: inbox, pairingStore: store, transport: StubBridgeTransport())

        XCTAssertTrue(sync.signOut())

        XCTAssertFalse(sync.isPaired)
        XCTAssertEqual(inbox.pending.count, 1, "signing out must not delete local inbox records")
    }

    func testSwitchDetectionOnlyFlagsADifferentEndpoint() async {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: StubPairingProbe())
        await store.pair(label: "x", endpointText: "https://a.example.com", credential: "c")

        XCTAssertFalse(store.isSwitch(to: "https://a.example.com/"))
        XCTAssertTrue(store.isSwitch(to: "https://b.example.com"))
    }

    // MARK: - Pairing validation (#58)

    func testPairingIsCheckedAgainstTheMailboxBeforeAnythingIsStored() async {
        let vault = InMemoryBridgeVault()
        let probe = StubPairingProbe()
        let store = CoachBridgePairingStore(vault: vault, probe: probe)

        guard case .success(let pairing) = await store.pair(
            label: "Alex's mailbox",
            endpointText: "https://coach.example.com",
            credential: "device-secret"
        ) else {
            return XCTFail("Expected pairing to succeed")
        }

        let credential = await probe.lastCredential()
        XCTAssertEqual(credential, "device-secret", "the check must carry the credential being paired")
        XCTAssertTrue(pairing.isVerified)
        XCTAssertTrue(CoachBridgePairingStore(vault: vault, probe: StubPairingProbe()).pairing?.isVerified == true)
    }

    func testRejectedCredentialFailsAtPairingTimeAndNamesTheCredential() async {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: StubPairingProbe([.credentialRejected]))

        let result = await store.pair(label: "x", endpointText: "https://coach.example.com", credential: "wrong")

        XCTAssertEqual(result, .failure(.credentialRejected))
        XCTAssertFalse(store.isPaired, "a rejected credential must not be stored")
        let message = CoachBridgePairingStore.PairingError.credentialRejected.localizedDescription
        XCTAssertTrue(message.contains("credential"))
        XCTAssertFalse(message.contains("wrong"), "no credential may reach a message or a log")
    }

    func testUnreachableAddressFailsAtPairingTimeAndNamesTheAddress() async {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: StubPairingProbe([.unreachable]))

        let result = await store.pair(label: "x", endpointText: "https://typo.example.com", credential: "c")

        XCTAssertEqual(result, .failure(.addressUnreachable))
        XCTAssertFalse(store.isPaired)
        XCTAssertTrue(
            CoachBridgePairingStore.PairingError.addressUnreachable.localizedDescription.contains("address")
        )
    }

    func testUnconfiguredDeploymentSaysTheMailboxIsNotReady() async {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: StubPairingProbe([.notReady]))

        let result = await store.pair(label: "x", endpointText: "https://coach.example.com", credential: "c")

        XCTAssertEqual(result, .failure(.mailboxNotReady))
        let message = CoachBridgePairingStore.PairingError.mailboxNotReady.localizedDescription
        XCTAssertTrue(message.contains("not set up"))
        XCTAssertFalse(message.contains("rejected"), "a 503 is neither a bad credential nor a bad address")
    }

    func testFailedValidationLeavesThePreviousPairingUsable() async {
        let vault = InMemoryBridgeVault()
        let store = CoachBridgePairingStore(vault: vault, probe: StubPairingProbe([.accepted, .credentialRejected]))
        await store.pair(label: "working", endpointText: "https://mine.example.com", credential: "good-secret")

        let result = await store.pair(label: "typo", endpointText: "https://theirs.example.com", credential: "bad-secret")

        XCTAssertEqual(result, .failure(.credentialRejected))
        XCTAssertEqual(store.pairing?.label, "working")
        XCTAssertEqual(store.pairing?.endpoint.absoluteString, "https://mine.example.com")
        XCTAssertEqual(store.credential(), "good-secret")
        // And nothing half-written landed in the vault either.
        let reloaded = CoachBridgePairingStore(vault: vault, probe: StubPairingProbe())
        XCTAssertEqual(reloaded.pairing?.label, "working")
        XCTAssertEqual(reloaded.credential(), "good-secret")
    }

    func testPairingOfflineIsSavedButReportedAsUnverified() async {
        let vault = InMemoryBridgeVault()
        let store = CoachBridgePairingStore(vault: vault, probe: StubPairingProbe([.offline]))

        guard case .success(let pairing) = await store.pair(
            label: "paired on a train",
            endpointText: "https://coach.example.com",
            credential: "c"
        ) else {
            return XCTFail("Expected an offline pairing to be saved")
        }

        XCTAssertFalse(pairing.isVerified)
        XCTAssertFalse(
            CoachBridgePairingStore(vault: vault, probe: StubPairingProbe()).pairing?.isVerified == true,
            "unverified must survive relaunch, or the screen would start claiming a check that never happened"
        )
    }

    func testASuccessfulRequestSettlesAnUnverifiedPairing() async throws {
        let vault = InMemoryBridgeVault()
        let store = CoachBridgePairingStore(vault: vault, probe: StubPairingProbe([.offline]))
        await store.pair(label: "x", endpointText: "https://coach.example.com", credential: "c")
        XCTAssertFalse(store.pairing?.isVerified == true)

        let transport = StubBridgeTransport()
        await transport.stub("GET /device/pending-patches", status: 200, json: "{\"patches\":[]}")
        let sync = try await makeSync(pairingStore: store, transport: transport)
        _ = await sync.pullPendingPatches()

        XCTAssertTrue(store.pairing?.isVerified == true)
    }

    func testABare200FromSomethingElseDoesNotSettleAnUnverifiedPairing() async throws {
        // An offline pairing can hold a wrong address, and a wrong https host
        // can answer 200 with anything. Only a response Flow recognises as the
        // device edge counts as proof.
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: StubPairingProbe([.offline]))
        await store.pair(label: "x", endpointText: "https://not-a-mailbox.example.com", credential: "c")

        let transport = StubBridgeTransport()
        await transport.stub("GET /device/pending-patches", status: 200, json: "{\"hello\":\"world\"}")
        let sync = try await makeSync(pairingStore: store, transport: transport)
        _ = await sync.pullPendingPatches()

        XCTAssertFalse(store.pairing?.isVerified == true)
    }

    func testASnapshotThatFailsIdentityDoesNotSettleAnUnverifiedPairing() async throws {
        let store = CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: StubPairingProbe([.offline]))
        await store.pair(label: "x", endpointText: "https://coach.example.com", credential: "c")

        let transport = StubBridgeTransport()
        await transport.stub(
            "PUT /device/snapshots",
            status: 201,
            json: "{\"stored\":true,\"contextId\":\"11111111-1111-1111-1111-111111111111\"}"
        )
        let sync = try await makeSync(pairingStore: store, transport: transport)
        sync.approveSharing()
        let result = await sync.syncToCoach(routines: [], strengthWorkouts: [], cardioWorkouts: [])

        XCTAssertEqual(result, .failure(.identityMismatch))
        XCTAssertFalse(store.pairing?.isVerified == true, "a response Flow did not trust cannot settle the pairing")
    }

    func testRotationWithARejectedCredentialKeepsTheWorkingOne() async {
        let store = CoachBridgePairingStore(
            vault: InMemoryBridgeVault(),
            probe: StubPairingProbe([.accepted, .credentialRejected])
        )
        await store.pair(label: "x", endpointText: "https://coach.example.com", credential: "working")

        let result = await store.rotateCredential("fat-fingered")

        XCTAssertEqual(result, .failure(.credentialRejected))
        XCTAssertEqual(store.credential(), "working")
    }

    func testRotationRefusesToReplaceAWorkingCredentialUnchecked() async {
        let store = CoachBridgePairingStore(
            vault: InMemoryBridgeVault(),
            probe: StubPairingProbe([.accepted, .offline])
        )
        await store.pair(label: "x", endpointText: "https://coach.example.com", credential: "working")

        let result = await store.rotateCredential("new")

        XCTAssertEqual(result, .failure(.cannotRotateOffline))
        XCTAssertEqual(store.credential(), "working")
    }

    func testAPairingWrittenBeforeValidationExistedCountsAsVerified() {
        // A version 1 record predates the check and belongs to an installation
        // that has been syncing with it; it must not suddenly read as unproven.
        let legacy = """
        {"schemaVersion":1,"label":"Alex's mailbox","endpoint":"https://coach.example.com",\
        "credential":"device-secret","pairedAt":"2026-07-25T12:00:00Z"}
        """
        let store = CoachBridgePairingStore(
            vault: InMemoryBridgeVault(stored: Data(legacy.utf8)),
            probe: StubPairingProbe()
        )

        XCTAssertTrue(store.pairing?.isVerified == true)
        XCTAssertEqual(store.credential(), "device-secret")
    }

    func testProbeReadsTheDeviceEdgeAndRejectsAHostThatIsNotAMailbox() async {
        let transport = StubBridgeTransport()
        await transport.stub("GET /device/pending-patches", status: 200, json: "{\"patches\":[]}")
        await transport.stub("GET /device/pending-patches", status: 200, json: "{\"hello\":\"world\"}")
        await transport.stub("GET /device/pending-patches", status: 401, json: "{\"error\":\"Invalid or missing credential.\"}")
        await transport.stub("GET /device/pending-patches", status: 503, json: "{\"error\":\"Mailbox deployment is not configured.\"}")
        let probe = CoachBridgeEdgeProbe(transport: transport)
        let endpoint = URL(string: "https://coach.example.com")!

        let accepted = await probe.check(endpoint: endpoint, credential: "c")
        let stranger = await probe.check(endpoint: endpoint, credential: "c")
        let rejected = await probe.check(endpoint: endpoint, credential: "c")
        let unconfigured = await probe.check(endpoint: endpoint, credential: "c")

        XCTAssertEqual(accepted, .accepted)
        XCTAssertEqual(stranger, .notAMailbox, "a 200 from something that is not the device edge is not a mailbox")
        XCTAssertEqual(rejected, .credentialRejected)
        XCTAssertEqual(unconfigured, .notReady)
        let calls = await transport.requests()
        XCTAssertTrue(calls.allSatisfy { $0.method == "GET" }, "the check must have no side effects")
    }

    func testProbeSeparatesAnOfflineDeviceFromAnUnreachableAddress() async {
        let offlineTransport = StubBridgeTransport()
        await offlineTransport.stubOffline("GET /device/pending-patches")
        let unreachableTransport = StubBridgeTransport()
        await unreachableTransport.stubFailure("GET /device/pending-patches")
        let endpoint = URL(string: "https://coach.example.com")!

        let offline = await CoachBridgeEdgeProbe(transport: offlineTransport).check(endpoint: endpoint, credential: "c")
        let unreachable = await CoachBridgeEdgeProbe(transport: unreachableTransport).check(endpoint: endpoint, credential: "c")

        XCTAssertEqual(offline, .offline)
        XCTAssertEqual(unreachable, .unreachable)
    }

    // MARK: - Sharing approval

    func testFirstSyncRequiresExplicitSharingApproval() async throws {
        let transport = StubBridgeTransport()
        let sync = try await makeSync(transport: transport)

        XCTAssertTrue(sync.requiresSharingApproval)
        let result = await sync.syncToCoach(routines: [], strengthWorkouts: [], cardioWorkouts: [])

        XCTAssertEqual(result, .failure(.sharingNotApproved))
        let count = await transport.requests().count
        XCTAssertEqual(count, 0, "nothing may leave the device before the categories are approved")
    }

    func testChangingSharingSelectionRevokesApproval() async throws {
        let sync = try await makeSync()
        sync.approveSharing()
        XCTAssertFalse(sync.requiresSharingApproval)

        sync.updateSharingProfile(FlowCoachSharingProfile(dataTiers: [.routines, .strengthHistory, .healthMetrics]))

        XCTAssertTrue(sync.requiresSharingApproval, "a widened selection must be re-approved")
    }

    func testDefaultSharingProfileIsRoutinesAndStrengthHistoryOnly() async throws {
        let sync = try await makeSync()
        XCTAssertEqual(sync.sharingProfile.dataTiers, [.routines, .strengthHistory])
        XCTAssertFalse(sync.sharingProfile.includes(.cardioHistory))
        XCTAssertFalse(sync.sharingProfile.includes(.healthMetrics))
    }

    func testSharingSelectionAndApprovalSurviveReload() async throws {
        let stateURL = try makeFileURL("coach-bridge-state.json")
        let inboxURL = try makeFileURL("coach-inbox.json")
        let profile = FlowCoachSharingProfile(dataTiers: [.routines, .strengthHistory, .cardioHistory])
        do {
            let sync = try await makeSync(inboxURL: inboxURL, stateURL: stateURL)
            sync.updateSharingProfile(profile)
            sync.approveSharing()
        }

        let reloaded = try await makeSync(inboxURL: inboxURL, stateURL: stateURL)
        XCTAssertEqual(reloaded.sharingProfile.dataTiers, profile.dataTiers)
        XCTAssertFalse(reloaded.requiresSharingApproval)
    }

    // MARK: - Sharing escalation (#60)

    func testEscalationTiersAreTheTwoOptInsAndNothingElse() {
        XCTAssertEqual(CoachBridgeSyncView.recommendedTiers, [.routines, .strengthHistory])
        XCTAssertEqual(CoachBridgeSyncView.escalationTiers, [.cardioHistory, .healthMetrics])
        XCTAssertEqual(
            CoachBridgeSyncView.tiersBeyondRecommended([.routines, .strengthHistory]),
            [],
            "the recommended pair is not an escalation of itself"
        )
        XCTAssertEqual(
            CoachBridgeSyncView.tiersBeyondRecommended(FlowCoachDataTier.allCases),
            [.cardioHistory, .healthMetrics]
        )
        XCTAssertTrue(CoachBridgeSyncView.isRecommendedSelection([.routines, .strengthHistory]))
        XCTAssertFalse(CoachBridgeSyncView.isRecommendedSelection([.routines]))
        XCTAssertFalse(CoachBridgeSyncView.isRecommendedSelection([.routines, .strengthHistory, .cardioHistory]))
    }

    func testMailboxSharingLineNamesAWiderThanRecommendedSelection() {
        let recommended = CoachBridgeSyncView.sharingSummary(
            for: [.routines, .strengthHistory],
            needsReview: false
        )
        let widened = CoachBridgeSyncView.sharingSummary(
            for: FlowCoachDataTier.allCases,
            needsReview: false
        )
        let unreviewed = CoachBridgeSyncView.sharingSummary(
            for: FlowCoachDataTier.allCases,
            needsReview: true
        )

        XCTAssertFalse(recommended.contains("wider"))
        XCTAssertTrue(widened.contains("wider than recommended"))
        XCTAssertTrue(widened.contains("cardio totals and health metrics"))
        // Needing review and being wider than recommended are different states
        // and must not read as the same thing.
        XCTAssertTrue(unreviewed.contains("needs review"))
        XCTAssertFalse(unreviewed.contains("wider"))
    }

    func testWideningTheSelectionStillRevokesApprovalAfterTheSheetChange() async throws {
        let sync = try await makeSync()
        sync.updateSharingProfile(FlowCoachSharingProfile(dataTiers: [.routines, .strengthHistory]))
        sync.approveSharing()

        sync.updateSharingProfile(FlowCoachSharingProfile(dataTiers: [.routines, .strengthHistory, .healthMetrics]))
        XCTAssertTrue(sync.requiresSharingApproval)

        // And narrowing it back is also a change, so it is re-approved too.
        sync.approveSharing()
        sync.updateSharingProfile(FlowCoachSharingProfile(dataTiers: [.routines, .strengthHistory]))
        XCTAssertTrue(sync.requiresSharingApproval)
    }

    // MARK: - Snapshot upload

    func testSyncUploadsEnvelopeAndRecordsReceipt() async throws {
        let transport = StubBridgeTransport()
        let sync = try await makeSync(transport: transport)
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
        let sync = try await makeSync(transport: transport)
        sync.approveSharing()

        let result = await sync.syncToCoach(routines: [], strengthWorkouts: [], cardioWorkouts: [])

        XCTAssertEqual(result, .failure(.identityMismatch))
        XCTAssertNil(sync.lastSnapshot, "an unverified upload must not be recorded as synced")
    }

    func testInvalidCredentialIsReportedAsRotatable() async throws {
        let transport = StubBridgeTransport()
        await transport.stub("PUT /device/snapshots", status: 401, json: "{\"error\":\"Invalid or missing credential.\"}")
        let sync = try await makeSync(transport: transport)
        sync.approveSharing()

        let result = await sync.syncToCoach(routines: [], strengthWorkouts: [], cardioWorkouts: [])

        XCTAssertEqual(result, .failure(.invalidCredential))
        XCTAssertEqual(sync.lastSyncError, CoachBridgeError.invalidCredential.errorDescription)
    }

    func testUploadedEnvelopeExcludesUnselectedCategories() async throws {
        let transport = StubBridgeTransport()
        let sync = try await makeSync(transport: transport)
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
        let sync = try await makeSync(transport: transport)
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
        let sync = try await makeSync(transport: transport)
        sync.approveSharing()
        let contextId = await captureUploadedContextId(transport: transport, sync: sync, routines: [])
        await transport.stub("DELETE /device/snapshots/\(contextId)", status: 410, json: "{\"error\":\"expired\"}")

        let result = await sync.deleteSnapshot()

        assertSucceeded(result)
        XCTAssertNil(sync.lastSnapshot)
    }

    func testDeleteAllRemoteDataClearsReceiptAndOwedAcknowledgements() async throws {
        let transport = StubBridgeTransport()
        let sync = try await makeSync(transport: transport)
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
        let sync = try await makeSync(inbox: inbox, transport: transport)
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
        let sync = try await makeSync(inbox: inbox, transport: transport)
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
        let sync = try await makeSync(transport: transport)
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
            let sync = try await makeSync(inboxURL: inboxURL, stateURL: stateURL, transport: transport)
            await sync.recordDecision(bridgePatchId: "bridge-1", status: .applied)
            XCTAssertEqual(sync.pendingAcknowledgements.count, 1)
            XCTAssertEqual(sync.pendingAcknowledgements.first?.attempts, 1)
        }

        let reloaded = try await makeSync(inboxURL: inboxURL, stateURL: stateURL, transport: transport)
        XCTAssertEqual(reloaded.pendingAcknowledgements.first?.bridgePatchId, "bridge-1")
        XCTAssertEqual(reloaded.pendingAcknowledgements.first?.status, .applied)
    }

    func testQueuedAcknowledgementIsDeliveredOnALaterFlush() async throws {
        let transport = StubBridgeTransport()
        await transport.stubFailure("POST /device/pending-patches/bridge-1/ack")
        let sync = try await makeSync(transport: transport)
        await sync.recordDecision(bridgePatchId: "bridge-1", status: .applied)
        XCTAssertEqual(sync.pendingAcknowledgements.count, 1)

        await transport.stub("POST /device/pending-patches/bridge-1/ack", status: 200, json: "{\"acknowledged\":true}")
        await sync.flushAcknowledgements()

        XCTAssertTrue(sync.pendingAcknowledgements.isEmpty)
    }

    func testTerminalAcknowledgementFailureIsNotRetriedForever() async throws {
        let transport = StubBridgeTransport()
        await transport.stub("POST /device/pending-patches/bridge-1/ack", status: 404, json: "{\"error\":\"Patch was not found.\"}")
        let sync = try await makeSync(transport: transport)

        await sync.recordDecision(bridgePatchId: "bridge-1", status: .applied)

        XCTAssertTrue(sync.pendingAcknowledgements.isEmpty)
    }

    func testTerminalDecisionSupersedesAnUndeliveredPulledAcknowledgement() async throws {
        let transport = StubBridgeTransport()
        await transport.stubFailure("POST /device/pending-patches/bridge-1/ack")
        await transport.stubFailure("POST /device/pending-patches/bridge-1/ack")
        let sync = try await makeSync(transport: transport)

        await sync.recordDecision(bridgePatchId: "bridge-1", status: .pulled)
        await sync.recordDecision(bridgePatchId: "bridge-1", status: .applied)

        XCTAssertEqual(sync.pendingAcknowledgements.count, 1)
        XCTAssertEqual(sync.pendingAcknowledgements.first?.status, .applied)
    }

    func testAcknowledgementsAreNeverSentToADifferentMailbox() async throws {
        let transport = StubBridgeTransport()
        let vault = InMemoryBridgeVault()
        let pairingStore = CoachBridgePairingStore(vault: vault, probe: StubPairingProbe())
        await pairingStore.pair(label: "mine", endpointText: "https://mine.example.com", credential: "mine-secret")
        await transport.stubFailure("POST /device/pending-patches/bridge-1/ack")
        let sync = try await makeSync(pairingStore: pairingStore, transport: transport)
        await sync.recordDecision(bridgePatchId: "bridge-1", status: .applied)
        XCTAssertEqual(sync.pendingAcknowledgements.count, 1)

        // Switch to the other person's mailbox.
        await pairingStore.pair(label: "theirs", endpointText: "https://theirs.example.com", credential: "their-secret")
        await sync.flushAcknowledgements()

        XCTAssertTrue(sync.actionableAcknowledgements.isEmpty)
        let leaked = await transport.requests().filter { $0.authorization == "Bearer their-secret" }
        XCTAssertTrue(leaked.isEmpty, "no acknowledgement may be delivered with the new mailbox's credential")
    }

    func testSwitchingDiscardsAcknowledgementsAndSnapshotFromTheOldMailbox() async throws {
        let transport = StubBridgeTransport()
        let vault = InMemoryBridgeVault()
        let pairingStore = CoachBridgePairingStore(vault: vault, probe: StubPairingProbe())
        await pairingStore.pair(label: "mine", endpointText: "https://mine.example.com", credential: "mine-secret")
        let sync = try await makeSync(pairingStore: pairingStore, transport: transport)
        sync.approveSharing()
        _ = await captureUploadedContextId(transport: transport, sync: sync, routines: [])
        await transport.stubFailure("POST /device/pending-patches/bridge-1/ack")
        await sync.recordDecision(bridgePatchId: "bridge-1", status: .applied)
        XCTAssertEqual(sync.acknowledgementsLostBySwitching(), 1)

        await pairingStore.pair(label: "theirs", endpointText: "https://theirs.example.com", credential: "their-secret")
        sync.discardAcknowledgements(notMatching: pairingStore.pairing?.endpoint)

        XCTAssertTrue(sync.pendingAcknowledgements.isEmpty)
        XCTAssertNil(sync.lastSnapshot, "the previous mailbox's snapshot record must not follow the switch")
    }

    func testUnpairedSyncMakesNoNetworkCalls() async throws {
        let transport = StubBridgeTransport()
        let sync = try await makeSync(pairingStore: CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: StubPairingProbe()), transport: transport)

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
        let sync = try await makeSync(transport: transport)

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

    func testSnapshotReceiptKnowsWhenItHasExpired() async {
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
    ) async throws -> CoachBridgeSync {
        let resolvedInbox = try inbox ?? CoachPatchInbox(fileURL: inboxURL ?? makeFileURL("coach-inbox.json"))
        let resolvedPairing: CoachBridgePairingStore
        if let pairingStore {
            resolvedPairing = pairingStore
        } else {
            resolvedPairing = CoachBridgePairingStore(vault: InMemoryBridgeVault(), probe: StubPairingProbe())
            await resolvedPairing.pair(
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
