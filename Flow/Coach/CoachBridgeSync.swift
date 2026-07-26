import Foundation

/// HTTP boundary for the bridge device edge, injectable so tests drive the
/// whole sync client without a network or a running Worker.
protocol CoachBridgeTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionBridgeTransport: CoachBridgeTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoachBridgeError.malformedResponse
        }
        return (data, http)
    }
}

enum CoachBridgeError: LocalizedError, Equatable {
    case notPaired
    case sharingNotApproved
    case invalidCredential
    case snapshotGone(String)
    case notFound(String)
    case rejected(status: Int, detail: String?)
    case transport(String)
    /// This device has no connection at all, as opposed to a reachable network
    /// that cannot find the mailbox. Kept separate because the two need
    /// different things from the person: one is waiting, the other is a wrong
    /// address (#58).
    case offline
    case malformedResponse
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .notPaired:
            return "Flow is not paired with a coach mailbox yet."
        case .sharingNotApproved:
            return "Review what will be shared before the first sync."
        case .invalidCredential:
            return "The mailbox rejected this device's credential. Rotate it in pairing settings."
        case .snapshotGone(let detail):
            return detail
        case .notFound(let detail):
            return detail
        case .rejected(let status, let detail):
            return detail ?? "The mailbox refused the request (HTTP \(status))."
        case .transport(let detail):
            return "Could not reach the mailbox: \(detail)"
        case .offline:
            return "This device is offline, so Flow could not reach the mailbox."
        case .malformedResponse:
            return "The mailbox sent a response Flow could not read."
        case .identityMismatch:
            return "The mailbox stored a different snapshot than Flow sent. Nothing was trusted; try syncing again."
        }
    }

    /// Whether retrying the identical request could plausibly succeed. Only
    /// retryable failures keep an acknowledgement queued; a terminal one would
    /// otherwise retry forever.
    var isRetryable: Bool {
        switch self {
        case .transport, .offline:
            return true
        case .rejected(let status, _):
            return status == 429 || (500...599).contains(status)
        case .notPaired, .sharingNotApproved, .invalidCredential, .snapshotGone,
             .notFound, .malformedResponse, .identityMismatch:
            return false
        }
    }
}

/// One request against a mailbox's device edge.
///
/// Lives outside `CoachBridgeSync` because pairing has to make the same request
/// with the same status mapping before there is anything to sync with (#58).
enum CoachBridgeEdge {
    /// URLSession codes that mean this device has no connection, rather than
    /// meaning the address is wrong. Anything else stays `.transport`, because
    /// a reachable network that cannot find the host is a pairing problem.
    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .dataNotAllowed,
        .internationalRoamingOff,
        .callIsActive,
    ]

    static func request(
        endpoint: URL,
        path: String,
        method: String,
        body: Data?,
        credential: String,
        transport: CoachBridgeTransport
    ) async throws -> [String: Any] {
        guard let url = URL(string: endpoint.absoluteString + path) else {
            throw CoachBridgeError.transport("The mailbox address is not usable.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 30

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.perform(request)
        } catch let error as CoachBridgeError {
            throw error
        } catch let error as URLError where offlineCodes.contains(error.code) {
            throw CoachBridgeError.offline
        } catch {
            throw CoachBridgeError.transport(error.localizedDescription)
        }

        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let detail = payload["error"] as? String

        switch response.statusCode {
        case 200...299:
            return payload
        case 401, 403:
            throw CoachBridgeError.invalidCredential
        case 404:
            throw CoachBridgeError.notFound(detail ?? "The mailbox has no such record.")
        case 410:
            throw CoachBridgeError.snapshotGone(detail ?? "That coach snapshot has expired. Sync a fresh one.")
        default:
            throw CoachBridgeError.rejected(status: response.statusCode, detail: detail)
        }
    }
}

/// What a candidate endpoint and credential turned out to be (#58).
///
/// Deliberately finer-grained than `CoachBridgeError`: at pairing time the
/// person needs to know which of the two things they just typed is wrong,
/// because the fixes are different and only one of them is theirs to make.
enum CoachBridgePairingCheck: Equatable {
    case accepted
    case credentialRejected
    /// Something answered, but it is not a Flow coach mailbox.
    case notAMailbox
    /// A real mailbox deployment that has not been configured yet, which the
    /// person can fix from neither the address nor the credential.
    case notReady
    case unreachable
    case offline
    case refused(status: Int)
}

/// Proves an endpoint and a credential work together.
protocol CoachBridgePairingProbe: Sendable {
    func check(endpoint: URL, credential: String) async -> CoachBridgePairingCheck
}

/// The real probe: one cheap authenticated read against the device edge.
///
/// `GET /device/pending-patches` is retry-safe, has no side effects, and
/// exercises exactly the credential and the boundary that sync will use.
struct CoachBridgeEdgeProbe: CoachBridgePairingProbe {
    private let transport: CoachBridgeTransport

    init(transport: CoachBridgeTransport = URLSessionBridgeTransport()) {
        self.transport = transport
    }

    func check(endpoint: URL, credential: String) async -> CoachBridgePairingCheck {
        do {
            let payload = try await CoachBridgeEdge.request(
                endpoint: endpoint,
                path: "/device/pending-patches",
                method: "GET",
                body: nil,
                credential: credential,
                transport: transport
            )
            // An authenticated 200 from something that does not answer with a
            // patch list is not this mailbox: a wrong https host can answer 200
            // with anything at all.
            guard payload["patches"] is [Any] else { return .notAMailbox }
            return .accepted
        } catch CoachBridgeError.invalidCredential {
            return .credentialRejected
        } catch CoachBridgeError.offline {
            return .offline
        } catch CoachBridgeError.transport {
            return .unreachable
        } catch CoachBridgeError.notFound {
            return .notAMailbox
        } catch CoachBridgeError.rejected(let status, _) {
            return status == 503 ? .notReady : .refused(status: status)
        } catch {
            return .notAMailbox
        }
    }
}

/// One remote patch as pulled from the device edge.
struct CoachBridgePulledPatch: Equatable {
    let bridgePatchId: String
    let contextId: String
    let provenance: String?
    let cursor: Int
    /// The `FlowRoutinePatch` object re-encoded verbatim. Kept as text because
    /// the inbox stores raw JSON and validates it later against live routines.
    let patchJSON: String
}

/// What Flow last uploaded, so the UI can show expiry and deletion can target
/// the exact snapshot.
struct CoachBridgeSnapshotReceipt: Codable, Equatable {
    let contextId: UUID
    let uploadedAt: Date
    let expiresAt: Date
    let endpoint: URL
    let dataTiers: [FlowCoachDataTier]

    func isExpired(at date: Date = Date()) -> Bool {
        expiresAt <= date
    }
}

/// A lifecycle acknowledgement owed to the bridge.
///
/// Queued durably *after* the local decision has been persisted, so a lost
/// network response can never replay a local mutation. Bound to the endpoint it
/// belongs to: an acknowledgement for one person's mailbox must never be sent
/// to another's.
struct PendingBridgeAcknowledgement: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        case pulled
        case applied
        case rejected
        case stale
    }

    let id: UUID
    let bridgePatchId: String
    let status: Status
    let endpoint: URL
    let queuedAt: Date
    var attempts: Int
    var lastError: String?
}

/// The Flow-side coach sync client (#39).
///
/// Flow stays the authority: this type uploads an explicitly scoped snapshot,
/// pulls drafts into the existing durable inbox, and reports outcomes back. It
/// never applies a patch, and it never tells the bridge a patch was applied
/// before the routine and the local audit trail are safely on disk.
@MainActor
@Observable
final class CoachBridgeSync {
    let pairingStore: CoachBridgePairingStore

    private(set) var sharingProfile: FlowCoachSharingProfile
    /// When the person last confirmed the categories Flow would upload. Reset
    /// whenever the selection changes, so a widened tier is re-confirmed.
    private(set) var sharingApprovedAt: Date?
    private(set) var lastSnapshot: CoachBridgeSnapshotReceipt?
    private(set) var pendingAcknowledgements: [PendingBridgeAcknowledgement] = []
    private(set) var lastSyncError: String?
    private(set) var statusMessage: String?
    private(set) var isBusy = false

    private let inbox: CoachPatchInbox
    private let transport: CoachBridgeTransport
    private let fileURL: URL
    private static let schemaVersion = 1

    private struct StateFile: Codable {
        let schemaVersion: Int
        let sharingProfile: FlowCoachSharingProfile
        let sharingApprovedAt: Date?
        let lastSnapshot: CoachBridgeSnapshotReceipt?
        let acknowledgements: [PendingBridgeAcknowledgement]
    }

    init(
        inbox: CoachPatchInbox,
        // Built inside the initialiser rather than as a default argument:
        // default arguments are evaluated in a nonisolated context, and the
        // store is main-actor isolated.
        pairingStore: CoachBridgePairingStore? = nil,
        transport: CoachBridgeTransport = URLSessionBridgeTransport(),
        fileURL: URL? = nil
    ) {
        self.inbox = inbox
        self.pairingStore = pairingStore ?? CoachBridgePairingStore()
        self.transport = transport
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.fileURL = docs.appendingPathComponent("coach-bridge-state.json")
        }
        sharingProfile = .recommended
        load()
    }

    var isPaired: Bool { pairingStore.isPaired }

    var requiresSharingApproval: Bool { sharingApprovedAt == nil }

    /// Acknowledgements that belong to the mailbox currently paired. Anything
    /// else is inert until its own endpoint is paired again.
    var actionableAcknowledgements: [PendingBridgeAcknowledgement] {
        guard let endpoint = pairingStore.pairing?.endpoint else { return [] }
        return pendingAcknowledgements.filter { $0.endpoint == endpoint }
    }

    // MARK: - Sharing selection

    /// Changes which categories may leave the device. Any change clears the
    /// approval so the person sees and confirms the new list before it uploads.
    func updateSharingProfile(_ profile: FlowCoachSharingProfile) {
        guard profile != sharingProfile else { return }
        sharingProfile = profile
        sharingApprovedAt = nil
        save()
    }

    func approveSharing(now: Date = Date()) {
        sharingApprovedAt = now
        save()
    }

    // MARK: - Snapshot upload

    /// Uploads a fresh, user-initiated snapshot. Never called automatically:
    /// v1 has no background upload.
    @discardableResult
    func syncToCoach(
        routines: [Routine],
        strengthWorkouts: [CompletedWorkout],
        cardioWorkouts: [Run],
        constraintsNotes: String? = nil,
        now: Date = Date()
    ) async -> Result<CoachBridgeSnapshotReceipt, CoachBridgeError> {
        guard let pairing = pairingStore.pairing, let credential = pairingStore.credential() else {
            return finish(.failure(.notPaired))
        }
        guard sharingApprovedAt != nil else {
            return finish(.failure(.sharingNotApproved))
        }
        beginWork()

        let envelope = FlowCoachSnapshotEnvelope.make(
            routines: routines,
            strengthWorkouts: strengthWorkouts,
            cardioWorkouts: cardioWorkouts,
            sharingProfile: sharingProfile,
            createdAt: now,
            constraintsNotes: constraintsNotes
        )
        guard let body = try? FlowRoutineExchange.encoder().encode(envelope) else {
            return finish(.failure(.malformedResponse))
        }

        do {
            let payload = try await send(
                path: "/device/snapshots",
                method: "PUT",
                body: body,
                pairing: pairing,
                credential: credential
            )
            // The bridge must have stored the identity Flow sent. A different
            // contextId would mean later proposals correlate with a snapshot
            // this installation never made.
            guard let storedId = payload["contextId"] as? String,
                  storedId == envelope.contextId.uuidString else {
                return finish(.failure(.identityMismatch))
            }
            let receipt = CoachBridgeSnapshotReceipt(
                contextId: envelope.contextId,
                uploadedAt: envelope.createdAt,
                expiresAt: envelope.expiresAt,
                endpoint: pairing.endpoint,
                dataTiers: sharingProfile.dataTiers
            )
            lastSnapshot = receipt
            save()
            return finish(.success(receipt), message: "Synced to \(pairing.label).")
        } catch let error as CoachBridgeError {
            return finish(.failure(error))
        } catch {
            return finish(.failure(.transport(error.localizedDescription)))
        }
    }

    /// Deletes the snapshot Flow uploaded, which also drops any remote drafts
    /// derived from it. Drafts already pulled into the local inbox stay: the UI
    /// must say so, because remote deletion cannot retract them.
    @discardableResult
    func deleteSnapshot() async -> Result<Void, CoachBridgeError> {
        guard let pairing = pairingStore.pairing, let credential = pairingStore.credential() else {
            return finish(.failure(.notPaired))
        }
        guard let receipt = lastSnapshot else {
            return finish(.failure(.notFound("Flow has no record of an uploaded snapshot.")))
        }
        beginWork()
        do {
            _ = try await send(
                path: "/device/snapshots/\(receipt.contextId.uuidString)",
                method: "DELETE",
                body: nil,
                pairing: pairing,
                credential: credential
            )
            lastSnapshot = nil
            save()
            return finish(.success(()), message: "Coach snapshot deleted.")
        } catch let error as CoachBridgeError {
            // A snapshot the bridge has already expired or dropped is the
            // outcome the person asked for; clear the local record too.
            if case .notFound = error {
                lastSnapshot = nil
                save()
                return finish(.success(()), message: "That snapshot was already gone.")
            }
            if case .snapshotGone = error {
                lastSnapshot = nil
                save()
                return finish(.success(()), message: "That snapshot had already expired.")
            }
            return finish(.failure(error))
        } catch {
            return finish(.failure(.transport(error.localizedDescription)))
        }
    }

    /// Removes everything this mailbox holds for the paired person.
    @discardableResult
    func deleteAllRemoteData() async -> Result<Void, CoachBridgeError> {
        guard let pairing = pairingStore.pairing, let credential = pairingStore.credential() else {
            return finish(.failure(.notPaired))
        }
        beginWork()
        do {
            _ = try await send(
                path: "/device/data",
                method: "DELETE",
                body: nil,
                pairing: pairing,
                credential: credential
            )
            lastSnapshot = nil
            // Acknowledgements for this mailbox can never be delivered against
            // records that no longer exist.
            pendingAcknowledgements.removeAll { $0.endpoint == pairing.endpoint }
            save()
            return finish(.success(()), message: "All coach data in \(pairing.label) was deleted.")
        } catch let error as CoachBridgeError {
            return finish(.failure(error))
        } catch {
            return finish(.failure(.transport(error.localizedDescription)))
        }
    }

    // MARK: - Pull

    /// Pulls pending drafts into the existing inbox.
    ///
    /// Ordering matters: a draft is acknowledged as `pulled` only after the
    /// inbox write succeeded, so a crash between the two leaves the bridge
    /// still offering it rather than believing Flow has it.
    @discardableResult
    func pullPendingPatches() async -> Result<Int, CoachBridgeError> {
        guard let pairing = pairingStore.pairing, let credential = pairingStore.credential() else {
            return finish(.failure(.notPaired))
        }
        beginWork()
        do {
            let payload = try await send(
                path: "/device/pending-patches",
                method: "GET",
                body: nil,
                pairing: pairing,
                credential: credential
            )
            let pulled = Self.decodePulledPatches(from: payload)
            var newCount = 0
            var failedWrite: String?

            for patch in pulled {
                let outcome = inbox.enqueueBridge(
                    rawJSON: patch.patchJSON,
                    bridgePatchId: patch.bridgePatchId,
                    contextId: patch.contextId,
                    assistantProvider: patch.provenance
                )
                switch outcome {
                case .added:
                    newCount += 1
                    queueAcknowledgement(bridgePatchId: patch.bridgePatchId, status: .pulled, endpoint: pairing.endpoint)
                case .duplicate:
                    // Already durably held. Re-acknowledging is idempotent and
                    // recovers the case where the previous ack never landed.
                    queueAcknowledgement(bridgePatchId: patch.bridgePatchId, status: .pulled, endpoint: pairing.endpoint)
                case .rejected(let reason):
                    // Do not acknowledge what Flow could not store.
                    failedWrite = reason
                }
            }
            save()
            await flushAcknowledgements()

            if let failedWrite {
                return finish(.failure(.rejected(status: 0, detail: "Some drafts could not be saved locally: \(failedWrite)")))
            }
            let message = newCount == 0
                ? "No new coach drafts."
                : "Pulled \(newCount) coach draft\(newCount == 1 ? "" : "s")."
            return finish(.success(newCount), message: message)
        } catch let error as CoachBridgeError {
            return finish(.failure(error))
        } catch {
            return finish(.failure(.transport(error.localizedDescription)))
        }
    }

    // MARK: - Acknowledgement

    /// Records a local decision for delivery to the bridge.
    ///
    /// Callers must already have persisted the local outcome: the routine, the
    /// inbox status, and the edit-history entry. This only owes the bridge a
    /// status update, and retries it without ever re-running the local change.
    func recordDecision(bridgePatchId: String, status: PendingBridgeAcknowledgement.Status) async {
        guard let endpoint = pairingStore.pairing?.endpoint else { return }
        queueAcknowledgement(bridgePatchId: bridgePatchId, status: status, endpoint: endpoint)
        save()
        await flushAcknowledgements()
    }

    /// Attempts every acknowledgement owed to the currently paired mailbox.
    func flushAcknowledgements() async {
        guard let pairing = pairingStore.pairing, let credential = pairingStore.credential() else { return }
        let owed = pendingAcknowledgements.filter { $0.endpoint == pairing.endpoint }
        guard !owed.isEmpty else { return }

        for ack in owed {
            do {
                _ = try await send(
                    path: "/device/pending-patches/\(ack.bridgePatchId)/ack",
                    method: "POST",
                    body: try? JSONEncoder().encode(["status": ack.status.rawValue]),
                    pairing: pairing,
                    credential: credential
                )
                pendingAcknowledgements.removeAll { $0.id == ack.id }
            } catch let error as CoachBridgeError {
                if error.isRetryable {
                    markAttempt(ack.id, error: error.localizedDescription)
                } else {
                    // Nothing further can be delivered for this record; keeping
                    // it would retry forever. The local decision already stands.
                    pendingAcknowledgements.removeAll { $0.id == ack.id }
                }
            } catch {
                markAttempt(ack.id, error: error.localizedDescription)
            }
        }
        save()
    }

    private func queueAcknowledgement(
        bridgePatchId: String,
        status: PendingBridgeAcknowledgement.Status,
        endpoint: URL,
        now: Date = Date()
    ) {
        // One outstanding acknowledgement per record per endpoint: a terminal
        // decision supersedes an undelivered `pulled`.
        pendingAcknowledgements.removeAll { $0.bridgePatchId == bridgePatchId && $0.endpoint == endpoint }
        pendingAcknowledgements.append(
            PendingBridgeAcknowledgement(
                id: UUID(),
                bridgePatchId: bridgePatchId,
                status: status,
                endpoint: endpoint,
                queuedAt: now,
                attempts: 0,
                lastError: nil
            )
        )
    }

    private func markAttempt(_ id: UUID, error: String) {
        guard let index = pendingAcknowledgements.firstIndex(where: { $0.id == id }) else { return }
        pendingAcknowledgements[index].attempts += 1
        pendingAcknowledgements[index].lastError = error
    }

    // MARK: - Pairing changes

    /// Drops acknowledgements that do not belong to the given endpoint, used
    /// when switching mailboxes so nothing queued for one person is ever
    /// delivered to another.
    func discardAcknowledgements(notMatching endpoint: URL?) {
        pendingAcknowledgements.removeAll { $0.endpoint != endpoint }
        if let receipt = lastSnapshot, receipt.endpoint != endpoint {
            lastSnapshot = nil
        }
        save()
    }

    /// How many acknowledgements a switch away from the current mailbox would
    /// discard, so the warning can be specific.
    func acknowledgementsLostBySwitching() -> Int {
        guard let endpoint = pairingStore.pairing?.endpoint else { return 0 }
        return pendingAcknowledgements.filter { $0.endpoint == endpoint }.count
    }

    /// Signing out stops remote calls but keeps local routines, inbox records,
    /// and history. Undelivered acknowledgements are kept: pairing the same
    /// mailbox again should still settle them.
    @discardableResult
    func signOut() -> Bool {
        let signedOut = pairingStore.unpair()
        if signedOut {
            statusMessage = "Signed out of the coach mailbox. Local routines and history are untouched."
            lastSyncError = nil
        }
        return signedOut
    }

    // MARK: - Requests

    private func send(
        path: String,
        method: String,
        body: Data?,
        pairing: CoachBridgePairing,
        credential: String
    ) async throws -> [String: Any] {
        let payload = try await CoachBridgeEdge.request(
            endpoint: pairing.endpoint,
            path: path,
            method: method,
            body: body,
            credential: credential,
            transport: transport
        )
        // A request the mailbox accepted is proof the pairing works, which
        // settles a pairing that was saved offline and never checked (#58).
        pairingStore.markVerified(pairing.endpoint)
        return payload
    }

    static func decodePulledPatches(from payload: [String: Any]) -> [CoachBridgePulledPatch] {
        guard let rows = payload["patches"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let bridgePatchId = row["patchId"] as? String,
                  let contextId = row["contextId"] as? String,
                  let patchObject = row["patch"],
                  JSONSerialization.isValidJSONObject(patchObject),
                  let patchData = try? JSONSerialization.data(withJSONObject: patchObject, options: [.sortedKeys]),
                  let patchJSON = String(data: patchData, encoding: .utf8) else {
                return nil
            }
            return CoachBridgePulledPatch(
                bridgePatchId: bridgePatchId,
                contextId: contextId,
                provenance: row["provenance"] as? String,
                cursor: row["cursor"] as? Int ?? 0,
                patchJSON: patchJSON
            )
        }
    }

    // MARK: - Status plumbing

    private func beginWork() {
        isBusy = true
        lastSyncError = nil
        statusMessage = nil
    }

    private func finish<T>(_ result: Result<T, CoachBridgeError>, message: String? = nil) -> Result<T, CoachBridgeError> {
        isBusy = false
        switch result {
        case .success:
            statusMessage = message
            lastSyncError = nil
        case .failure(let error):
            lastSyncError = error.localizedDescription
        }
        return result
    }

    // MARK: - Persistence

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let file = StateFile(
                schemaVersion: Self.schemaVersion,
                sharingProfile: sharingProfile,
                sharingApprovedAt: sharingApprovedAt,
                lastSnapshot: lastSnapshot,
                acknowledgements: pendingAcknowledgements
            )
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            // Losing this file costs a re-approval and possibly a duplicate
            // acknowledgement, both harmless; it must never block a local
            // decision that has already been saved.
            lastSyncError = "Could not save coach sync state: \(error.localizedDescription)"
            print("Failed to save coach bridge state: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(StateFile.self, from: Data(contentsOf: fileURL))
            sharingProfile = file.sharingProfile
            sharingApprovedAt = file.sharingApprovedAt
            lastSnapshot = file.lastSnapshot
            pendingAcknowledgements = file.acknowledgements
        } catch {
            lastSyncError = "Could not load coach sync state: \(error.localizedDescription)"
            print("Failed to load coach bridge state: \(error)")
        }
    }
}
