import Foundation

/// One received routine patch, durable until the user resolves it.
///
/// The record is deliberately transport-agnostic: paste, file import, deep
/// link, and the future bridge sync (#39) all produce the same shape, so the
/// bridge never needs a parallel inbox. `rawJSON` is the source of truth;
/// validation always runs against the routines as they are now, never against
/// anything cached at arrival time.
struct PendingCoachPatch: Codable, Equatable, Identifiable {
    enum Source: String, Codable {
        case paste
        case file
        case deepLink
        /// Reserved for the phase 8 bridge sync client (#39).
        case bridge
    }

    enum Status: String, Codable {
        case pending
        case applied
        case rejected
    }

    let id: UUID
    let receivedAt: Date
    let source: Source
    /// Which assistant produced the patch, when the transport can say
    /// (deep links may carry `provider=`; the bridge will always know).
    let assistantProvider: String?
    let rawJSON: String
    var status: Status
    var resolvedAt: Date?
}

/// How a pending patch relates to the routines as they are right now.
/// Computed fresh from a full preview, never stored: a patch that was ready
/// yesterday may conflict today.
struct PendingCoachPatchSummary: Equatable {
    enum Readiness: Equatable {
        /// Previews cleanly against the pinned content hash.
        case ready
        /// Content hash is stale but every operation's expected before-value
        /// still matches, so Flow can rebase and preview.
        case rebase
        /// Content hash is stale and an operation no longer matches.
        case conflict(String)
        case invalid(String)
    }

    let readiness: Readiness
    let routineName: String?
    let rationale: String?
    let operationCount: Int
}

/// Durable local inbox for coach routine patches.
///
/// Owns `coach-inbox.json` and nothing else: routine mutation stays with
/// `RoutineStore`, and a patch leaves the pending state only through an
/// explicit apply or reject. The inbox also carries the app-level routing
/// state for opening the coach sheet, so a deep link can land a patch and
/// surface it from anywhere in the app.
@Observable
final class CoachPatchInbox {
    private(set) var patches: [PendingCoachPatch] = []
    /// Requests presentation of the coach sheet; the root view binds to this.
    var presentCoach = false
    /// One-line transport feedback (patch received, link unreadable, ...)
    /// shown inside the coach sheet.
    var notice: String?

    /// Patches above this size are rejected before they touch the inbox.
    /// Real patches are a few KB; this only guards against pasting something
    /// wildly wrong, like a workout export or a whole chat transcript.
    static let maxPatchBytes = 512 * 1024

    private static let inboxSchemaVersion = 1

    private struct InboxFile: Codable {
        let schemaVersion: Int
        let patches: [PendingCoachPatch]
    }

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.fileURL = docs.appendingPathComponent("coach-inbox.json")
        }
        load()
    }

    var pending: [PendingCoachPatch] {
        patches.filter { $0.status == .pending }.sorted { $0.receivedAt > $1.receivedAt }
    }

    var resolved: [PendingCoachPatch] {
        patches.filter { $0.status != .pending }.sorted { ($0.resolvedAt ?? $0.receivedAt) > ($1.resolvedAt ?? $1.receivedAt) }
    }

    enum EnqueueOutcome: Equatable {
        case added(PendingCoachPatch)
        case duplicate(PendingCoachPatch)
        case rejected(String)
    }

    @discardableResult
    func enqueue(rawJSON: String, source: PendingCoachPatch.Source, assistantProvider: String? = nil) -> EnqueueOutcome {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected("There was no patch text to import.")
        }
        guard trimmed.utf8.count <= Self.maxPatchBytes else {
            return .rejected("Patch is too large to be a routine patch.")
        }
        // The same patch arriving twice (double paste, re-tapped link) should
        // not stack up as separate inbox entries.
        let sanitised = FlowRoutineExchange.sanitizedJSON(from: trimmed)
        if let existing = pending.first(where: { FlowRoutineExchange.sanitizedJSON(from: $0.rawJSON) == sanitised }) {
            return .duplicate(existing)
        }

        let patch = PendingCoachPatch(
            id: UUID(),
            receivedAt: Date(),
            source: source,
            assistantProvider: assistantProvider,
            rawJSON: trimmed,
            status: .pending,
            resolvedAt: nil
        )
        patches.append(patch)
        save()
        return .added(patch)
    }

    func markApplied(_ id: UUID) {
        resolve(id, as: .applied)
    }

    func markRejected(_ id: UUID) {
        resolve(id, as: .rejected)
    }

    func remove(_ id: UUID) {
        patches.removeAll { $0.id == id }
        save()
    }

    func clearResolved() {
        patches.removeAll { $0.status != .pending }
        save()
    }

    /// Full-preview classification of a pending patch against the current
    /// routines. Runs the same code path the preview screen uses, so the
    /// inbox rows can never disagree with what tapping one shows.
    func summary(for patch: PendingCoachPatch, routines: [Routine]) -> PendingCoachPatchSummary {
        let decoded = try? FlowRoutineExchange.decoder().decode(
            FlowRoutinePatch.self,
            from: Data(FlowRoutineExchange.sanitizedJSON(from: patch.rawJSON).utf8)
        )
        let routineName = decoded.flatMap { patch in routines.first { $0.id == patch.routineId }?.name }
        let rationale = decoded.map(\.rationale)
        let operationCount = decoded?.operations.count ?? 0

        do {
            let preview = try FlowRoutinePatcher.preview(json: patch.rawJSON, routines: routines)
            return PendingCoachPatchSummary(
                readiness: preview.rebasedFromHash == nil ? .ready : .rebase,
                routineName: preview.originalRoutine.name,
                rationale: preview.patch.rationale,
                operationCount: preview.patch.operations.count
            )
        } catch let error as FlowRoutinePatchError {
            let readiness: PendingCoachPatchSummary.Readiness
            if case .staleConflict = error {
                readiness = .conflict(error.localizedDescription)
            } else {
                readiness = .invalid(error.localizedDescription)
            }
            return PendingCoachPatchSummary(
                readiness: readiness,
                routineName: routineName,
                rationale: rationale,
                operationCount: operationCount
            )
        } catch {
            return PendingCoachPatchSummary(
                readiness: .invalid(error.localizedDescription),
                routineName: routineName,
                rationale: rationale,
                operationCount: operationCount
            )
        }
    }

    // MARK: - Incoming URLs

    /// Entry point for everything `onOpenURL` delivers: `flow://coach` deep
    /// links and JSON files opened into the app. Anything recognised opens
    /// the coach sheet; patch payloads land in the inbox first.
    func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            ingestFile(at: url)
            presentCoach = true
            return
        }

        switch FlowCoachDeepLink.parse(url) {
        case .success(.openCoach):
            presentCoach = true
        case .success(.importPatch(let json, let provider)):
            notice = noticeText(
                for: enqueue(rawJSON: json, source: .deepLink, assistantProvider: provider),
                receivedVia: provider.map { "link from \($0)" } ?? "link"
            )
            presentCoach = true
        case .failure(.notCoachURL):
            // Not ours (some other future URL type); stay out of the way.
            return
        case .failure(let error):
            notice = error.localizedDescription
            presentCoach = true
        }
    }

    /// Reads a JSON patch file (document picker, or a file shared into the
    /// app) into the inbox.
    @discardableResult
    func ingestFile(at url: URL) -> EnqueueOutcome {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let outcome: EnqueueOutcome
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            outcome = enqueue(rawJSON: text, source: .file)
        } else {
            outcome = .rejected("Could not read \(url.lastPathComponent) as text.")
        }
        notice = noticeText(for: outcome, receivedVia: url.lastPathComponent)
        return outcome
    }

    private func noticeText(for outcome: EnqueueOutcome, receivedVia transport: String) -> String {
        switch outcome {
        case .added:
            return "Patch received via \(transport). Review it below."
        case .duplicate:
            return "This patch is already in the inbox."
        case .rejected(let reason):
            return reason
        }
    }

    private func resolve(_ id: UUID, as status: PendingCoachPatch.Status) {
        guard let index = patches.firstIndex(where: { $0.id == id }) else { return }
        patches[index].status = status
        patches[index].resolvedAt = Date()
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(InboxFile(schemaVersion: Self.inboxSchemaVersion, patches: patches))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save coach inbox: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            patches = try decoder.decode(InboxFile.self, from: data).patches
        } catch {
            preserveCorruptFile()
            print("Failed to load coach inbox: \(error)")
        }
    }

    private func preserveCorruptFile() {
        let backupName = "coach-inbox.corrupt-\(Int(Date().timeIntervalSince1970)).json"
        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(backupName)
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
    }
}
