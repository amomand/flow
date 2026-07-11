import Foundation

/// One applied coach patch, recorded at the moment `RoutineStore` saved it.
///
/// This is the after-apply audit side of the coach exchange: `CoachPatchInbox`
/// holds patches before apply, this record holds what an apply actually did
/// and enough previous state to undo it. It stores routine sections and patch
/// metadata only; HealthKit data and route data never enter the history.
struct CoachEditRecord: Codable, Equatable, Identifiable {
    enum Outcome: String, Codable {
        case applied
        /// The edit was rolled back by restoring `previousSections`.
        case restored
    }

    let id: UUID
    let appliedAt: Date
    let routineId: UUID
    /// Name at apply time, so the entry stays legible if the routine is
    /// later renamed or deleted.
    let routineName: String
    /// The content hash the patch pinned to (`baseContentHash`).
    let baseContentHash: String
    /// The routine's actual content hash at apply time; differs from
    /// `baseContentHash` when the patch was cleanly rebased.
    let appliedFromContentHash: String
    let resultingContentHash: String
    let rationale: String
    let diffs: [FlowRoutinePatchDiff]
    /// The sections as they were before the patch applied: everything needed
    /// to restore. Patches only ever edit sections, so restore grafts these
    /// onto the current routine and leaves non-structural state alone.
    let previousSections: [Section]
    let provenance: CoachEditProvenance?
    var outcome: Outcome
    var restoredAt: Date?

    var wasRebased: Bool {
        baseContentHash != appliedFromContentHash
    }
}

/// Where an applied patch came from, mirroring the lifecycle fields the
/// bridge uses (#38/#39). Manual transports fill what they know: the inbox
/// record id and, for deep links, the assistant provider. Bridge-delivered
/// patches also preserve the distinct remote patch and snapshot identities.
struct CoachEditProvenance: Codable, Equatable {
    let sourcePatchId: UUID?
    let bridgePatchId: String?
    let contextId: String?
    let assistantProvider: String?
    let source: PendingCoachPatch.Source?

    init(
        sourcePatchId: UUID?,
        bridgePatchId: String? = nil,
        contextId: String?,
        assistantProvider: String?,
        source: PendingCoachPatch.Source?
    ) {
        self.sourcePatchId = sourcePatchId
        self.bridgePatchId = bridgePatchId
        self.contextId = contextId
        self.assistantProvider = assistantProvider
        self.source = source
    }
}

/// Durable audit log for applied coach patches (`coach-edit-history.json`).
///
/// The store is append-and-mark only: entries are added when a patch
/// applies, and `markRestored` flips an entry's outcome when it is rolled
/// back. Restoring routines is `RoutineStore`'s job; this store never
/// touches `routines.json`, and a corrupt or missing history file can only
/// ever cost history, never routines.
@Observable
final class CoachEditHistoryStore {
    private(set) var records: [CoachEditRecord] = []
    private(set) var persistenceError: String?

    enum PersistenceError: LocalizedError, Equatable {
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let message):
                return message
            }
        }
    }

    /// Oldest entries are pruned beyond this. Twenty applied edits of a
    /// personal routine set is far more undo depth than the product needs.
    static let maxRecords = 20

    private static let historySchemaVersion = 1

    private struct HistoryFile: Codable {
        let schemaVersion: Int
        let records: [CoachEditRecord]
    }

    private let fileURL: URL
    private let fileWriter: (Data, URL) throws -> Void

    init(
        fileURL: URL? = nil,
        fileWriter: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.fileURL = docs.appendingPathComponent("coach-edit-history.json")
        }
        self.fileWriter = fileWriter
        load()
    }

    var newestFirst: [CoachEditRecord] {
        records.sorted { $0.appliedAt > $1.appliedAt }
    }

    /// The most recent edit still in the applied state: the quick-undo target.
    var mostRecentRestorable: CoachEditRecord? {
        newestFirst.first { $0.outcome == .applied }
    }

    @discardableResult
    func record(_ entry: CoachEditRecord) -> Result<Void, PersistenceError> {
        let previous = records
        records.append(entry)
        if records.count > Self.maxRecords {
            records.sort { $0.appliedAt < $1.appliedAt }
            records.removeFirst(records.count - Self.maxRecords)
        }
        let result = save()
        if case .failure = result {
            records = previous
        }
        return result
    }

    @discardableResult
    func markRestored(_ id: UUID) -> Result<Void, PersistenceError> {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return .success(()) }
        let previous = records[index]
        records[index].outcome = .restored
        records[index].restoredAt = Date()
        let result = save()
        if case .failure = result {
            records[index] = previous
        }
        return result
    }

    // MARK: - Persistence

    private func save() -> Result<Void, PersistenceError> {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(HistoryFile(schemaVersion: Self.historySchemaVersion, records: records))
            try fileWriter(data, fileURL)
            persistenceError = nil
            return .success(())
        } catch {
            persistenceError = error.localizedDescription
            print("Failed to save coach edit history: \(error)")
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode(HistoryFile.self, from: data).records
        } catch {
            preserveCorruptFile()
            print("Failed to load coach edit history: \(error)")
        }
    }

    private func preserveCorruptFile() {
        let backupName = "coach-edit-history.corrupt-\(Int(Date().timeIntervalSince1970)).json"
        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(backupName)
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
    }
}
