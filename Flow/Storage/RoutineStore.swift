import Foundation

@Observable
class RoutineStore {
    var routines: [Routine] = []
    var loadError: String?
    private(set) var saveError: String?
    /// Audit log fed by every coach patch apply; nil only in tests that do
    /// not exercise the coach path.
    let editHistory: CoachEditHistoryStore?
    private static let seedVersion = "summer-arc-upper-core-v2"
    private static let seedVersionKey = "RoutineStore.seedVersion"

    private enum LoadResult {
        case missing
        case loaded
        case failed(Error)
    }

    private let fileURL: URL
    private let defaults: UserDefaults
    private let fileWriter: (Data, URL) throws -> Void
    private var loadResult: LoadResult = .missing

    init(
        fileURL: URL? = nil,
        defaults: UserDefaults = .standard,
        editHistory: CoachEditHistoryStore? = nil,
        fileWriter: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.fileURL = docs.appendingPathComponent("routines.json")
        }
        self.defaults = defaults
        self.editHistory = editHistory
        self.fileWriter = fileWriter
        loadResult = loadFromDisk()
        migrateSeedRoutinesIfNeeded()
    }

    enum PersistenceError: LocalizedError, Equatable {
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let message):
                return message
            }
        }
    }

    @discardableResult
    func save() -> Result<Void, PersistenceError> {
        do {
            let data = try JSONEncoder().encode(routines)
            try fileWriter(data, fileURL)
            saveError = nil
            return .success(())
        } catch {
            saveError = error.localizedDescription
            print("Failed to save routines: \(error)")
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    @discardableResult
    func load() -> Bool {
        switch loadFromDisk() {
        case .loaded:
            loadResult = .loaded
            return true
        case .missing:
            loadResult = .missing
            return false
        case .failed(let error):
            loadResult = .failed(error)
            return false
        }
    }

    private func loadFromDisk() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        do {
            let data = try Data(contentsOf: fileURL)
            routines = try JSONDecoder().decode([Routine].self, from: data)
            loadError = nil
            return .loaded
        } catch {
            loadError = error.localizedDescription
            preserveCorruptFile()
            print("Failed to load routines: \(error)")
            return .failed(error)
        }
    }

    @discardableResult
    func addRoutine(_ routine: Routine) -> Result<Void, PersistenceError> {
        routines.append(routine)
        let result = save()
        if case .failure = result {
            routines.removeLast()
        }
        return result
    }

    @discardableResult
    func updateRoutine(_ routine: Routine) -> Result<Void, PersistenceError> {
        if let idx = routines.firstIndex(where: { $0.id == routine.id }) {
            let previous = routines[idx]
            routines[idx] = routine
            let result = save()
            if case .failure = result {
                routines[idx] = previous
            }
            return result
        }
        return .success(())
    }

    /// Reorder the routine list.
    ///
    /// Order is the array's own order, which is what `routines.json` stores and
    /// what every screen reads, so there is nothing to sort by and no field to
    /// keep in step. Takes `IndexSet` and a destination because that is the
    /// shape SwiftUI's `onMove` hands over.
    ///
    /// Nothing here changes a routine's content, so no content hash moves and
    /// no coach patch is staled by a reorder.
    @discardableResult
    func moveRoutines(fromOffsets offsets: IndexSet, toOffset destination: Int) -> Result<Void, PersistenceError> {
        let previous = routines
        routines.move(fromOffsets: offsets, toOffset: destination)
        // A drag that ends where it started still calls through, and writing
        // the same array again is work for nothing.
        guard routines != previous else { return .success(()) }
        let result = save()
        if case .failure = result {
            routines = previous
        }
        return result
    }

    @discardableResult
    func deleteRoutine(at offsets: IndexSet) -> Result<Void, PersistenceError> {
        let previous = routines
        routines.remove(atOffsets: offsets)
        let result = save()
        if case .failure = result {
            routines = previous
        }
        return result
    }

    func exportRoutineJSON(_ routine: Routine) -> String? {
        guard let data = try? FlowRoutineExchange.encoder().encode(routine) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func importRoutineFromJSON(_ json: String) -> Result<Routine, ImportError> {
        // The count ceiling lives with the other snapshot bounds, but it is a
        // property of the collection, so the per-routine gate below cannot see
        // it: the 51st routine is individually flawless and still fails every
        // upload whole. The patch path already refuses a create at the cap;
        // this is the other route that grows the collection.
        guard routines.count < FlowRoutinePatcher.maximumRoutines else {
            return .failure(.outOfBounds("a snapshot carries at most \(FlowRoutinePatcher.maximumRoutines) routines, and there are already that many"))
        }
        let cleaned = FlowRoutineExchange.sanitizedJSON(from: json)
        guard let data = cleaned.data(using: .utf8) else {
            return .failure(.invalidJSON)
        }
        switch FlowRoutineExchange.detectPayload(in: cleaned) {
        case .coachPatch:
            return .failure(.looksLikeCoachPatch)
        case .coachContext:
            return .failure(.looksLikeCoachContext)
        case .routine, .unknown:
            break
        }
        do {
            var routine = try FlowRoutineExchange.decoder().decode(Routine.self, from: data)
            // Trimmed and bounded the same way the editors and the patch path
            // are, because this was the one remaining route that stored names
            // the snapshot schema refuses: the upload is validated whole, so
            // one over-long pasted name would cost the coach every routine at
            // the next sync, far from the import that caused it.
            routine = FlowTextBounds.withTrimmedNames(routine)
            if let problem = FlowTextBounds.firstBoundsProblem(in: routine) {
                return .failure(.outOfBounds(problem))
            }
            // Assign new IDs so imports never collide with existing routines
            routine.id = UUID()
            for si in routine.sections.indices {
                routine.sections[si].id = UUID()
                for ei in routine.sections[si].exercises.indices {
                    routine.sections[si].exercises[ei].id = UUID()
                }
            }
            routines.append(routine)
            if case .failure(let error) = save() {
                routines.removeLast()
                return .failure(.persistenceFailed(error.localizedDescription))
            }
            return .success(routine)
        } catch {
            return .failure(.decodingFailed(error.localizedDescription))
        }
    }

    func exportCoachContextJSON(
        strengthWorkouts: [CompletedWorkout],
        cardioWorkouts: [Run],
        constraintsNotes: String? = nil
    ) -> String? {
        FlowCoachContext
            .make(
                routines: routines,
                strengthWorkouts: strengthWorkouts,
                cardioWorkouts: cardioWorkouts,
                constraintsNotes: constraintsNotes
            )
            .jsonString()
    }

    func previewRoutinePatchJSON(_ json: String) -> Result<FlowRoutinePatchPreview, FlowRoutinePatchError> {
        do {
            return .success(try FlowRoutinePatcher.preview(json: json, routines: routines))
        } catch let error as FlowRoutinePatchError {
            return .failure(error)
        } catch {
            return .failure(.invalidJSON(error.localizedDescription))
        }
    }

    func applyRoutinePatchPreview(
        _ preview: FlowRoutinePatchPreview,
        provenance: CoachEditProvenance? = nil
    ) -> Result<Routine, FlowRoutinePatchError> {
        // Re-run the preview against the routines as they are at apply time.
        // The routine may have changed since the preview was built (including
        // a clean rebase), so apply is always revalidate-then-graft; a patch
        // whose operations no longer match fails here instead of clobbering
        // the newer content.
        let fresh: FlowRoutinePatchPreview
        do {
            fresh = try FlowRoutinePatcher.preview(patch: preview.patch, routines: routines)
        } catch let error as FlowRoutinePatchError {
            return .failure(error)
        } catch {
            return .failure(.invalidJSON(error.localizedDescription))
        }

        if fresh.isCreate {
            return applyCreatedRoutine(fresh, provenance: provenance)
        }

        // Separated so the error names what is actually wrong. An invented id
        // in a "no routine matches" message would send someone looking for a
        // routine that was never referred to.
        guard let routineId = fresh.patch.routineId else {
            return .failure(.missingField("routineId"))
        }
        guard let index = routines.firstIndex(where: { $0.id == routineId }) else {
            return .failure(.routineNotFound(routineId))
        }

        let current = routines[index]
        // Graft the patched structure onto the current routine rather than
        // replacing it wholesale: non-structural state such as currentPhase
        // may have changed since the preview was built (the content hash
        // deliberately ignores it), and applying a patch must not revert
        // that state. Patch operations edit sections and, since schema 3,
        // the routine name; both come from `fresh`, which was previewed
        // against the routine as it is right now, so grafting the name can
        // only ever carry a rename this patch actually made.
        var updated = current
        updated.sections = fresh.updatedRoutine.sections
        updated.name = fresh.updatedRoutine.name
        routines[index] = updated
        if case .failure(let error) = save() {
            routines[index] = current
            return .failure(.persistenceFailed(error.localizedDescription))
        }
        let historyResult = editHistory?.record(CoachEditRecord(
            id: UUID(),
            appliedAt: Date(),
            routineId: updated.id,
            routineName: updated.name,
            baseContentHash: fresh.patch.baseContentHash ?? FlowRoutineRevision.contentHash(for: current),
            appliedFromContentHash: FlowRoutineRevision.contentHash(for: current),
            resultingContentHash: FlowRoutineRevision.contentHash(for: updated),
            rationale: fresh.patch.rationale,
            diffs: fresh.diffs,
            previousSections: current.sections,
            previousName: current.name,
            createdRoutine: false,
            provenance: provenance,
            outcome: .applied,
            restoredAt: nil
        ))
        if let historyResult,
           case .failure(let error) = historyResult {
            routines[index] = current
            let rollback = save()
            let suffix: String
            if case .failure(let rollbackError) = rollback {
                routines[index] = updated
                suffix = " The routine file changed, and rollback also failed: \(rollbackError.localizedDescription)"
            } else {
                suffix = " The routine file was restored to its previous contents."
            }
            return .failure(.persistenceFailed("Could not write coach edit history: \(error.localizedDescription).\(suffix)"))
        }
        return .success(updated)
    }

    /// Applies a create.
    ///
    /// Insert rather than graft: there is nothing to graft onto, and nothing
    /// of the user's to preserve. The routine keeps the ids and the phase the
    /// patch specified, which is what makes applying the same create twice a
    /// no-op the second time rather than a second routine.
    private func applyCreatedRoutine(
        _ preview: FlowRoutinePatchPreview,
        provenance: CoachEditProvenance?
    ) -> Result<Routine, FlowRoutinePatchError> {
        let created = preview.updatedRoutine
        guard !routines.contains(where: { $0.id == created.id }) else {
            return .failure(.routineAlreadyExists(created.id))
        }

        routines.append(created)
        if case .failure(let error) = save() {
            routines.removeAll { $0.id == created.id }
            return .failure(.persistenceFailed(error.localizedDescription))
        }

        let contentHash = FlowRoutineRevision.contentHash(for: created)
        let historyResult = editHistory?.record(CoachEditRecord(
            id: UUID(),
            appliedAt: Date(),
            routineId: created.id,
            routineName: created.name,
            // A create pins to nothing, so the hash it applied from is the
            // hash it produced. `wasRebased` is false, which is true: there
            // was no earlier content to rebase over.
            baseContentHash: contentHash,
            appliedFromContentHash: contentHash,
            resultingContentHash: contentHash,
            rationale: preview.patch.rationale,
            diffs: preview.diffs,
            previousSections: [],
            previousName: nil,
            createdRoutine: true,
            provenance: provenance,
            outcome: .applied,
            restoredAt: nil
        ))
        if let historyResult, case .failure(let error) = historyResult {
            routines.removeAll { $0.id == created.id }
            let rollback = save()
            let suffix: String
            if case .failure(let rollbackError) = rollback {
                routines.append(created)
                suffix = " The routine file changed, and rollback also failed: \(rollbackError.localizedDescription)"
            } else {
                suffix = " The new routine was removed again."
            }
            return .failure(.persistenceFailed("Could not write coach edit history: \(error.localizedDescription).\(suffix)"))
        }
        return .success(created)
    }

    enum CoachEditRestoreError: LocalizedError, Equatable {
        case routineNotFound(String)
        case routineChangedSinceEdit(String)
        case persistenceFailed(String)

        var errorDescription: String? {
            switch self {
            case .routineNotFound(let name):
                return "\(name) no longer exists, so this edit cannot be restored."
            case .routineChangedSinceEdit(let name):
                return "\(name) changed after this edit was applied. Restoring will overwrite those later changes."
            case .persistenceFailed(let message):
                return "The restore was not saved: \(message)"
            }
        }
    }

    /// Rolls a routine back to the sections recorded before a coach edit
    /// applied. Writes through the same save path as every other mutation.
    /// When the routine has changed since the edit, restore refuses unless
    /// the caller explicitly allows overwriting the later changes.
    func restoreCoachEdit(
        _ record: CoachEditRecord,
        allowingOverwrite: Bool = false
    ) -> Result<Routine, CoachEditRestoreError> {
        guard let index = routines.firstIndex(where: { $0.id == record.routineId }) else {
            return .failure(.routineNotFound(record.routineName))
        }

        let current = routines[index]
        if !allowingOverwrite,
           FlowRoutineRevision.contentHash(for: current) != record.resultingContentHash {
            return .failure(.routineChangedSinceEdit(current.name))
        }

        // Undoing a create means the routine should not be here. There are no
        // sections to put back, and leaving an empty husk behind would be a
        // worse answer than either keeping it or removing it.
        //
        // This is the one undo that deletes, so it also checks the name, which
        // the content hash cannot see. Renaming a routine the coach added is
        // exactly how someone makes it their own, and it should not then
        // vanish on one tap without a word.
        if record.wasCreate {
            if !allowingOverwrite, current.name != record.routineName {
                return .failure(.routineChangedSinceEdit(current.name))
            }
            return removeCreatedRoutine(at: index, record: record)
        }
        // The content hash covers sections only, so it cannot see a rename
        // that happened after the edit. Where restore would put a name back,
        // check that name the same way, or an undo would quietly revert a
        // rename the user made by hand afterwards.
        //
        // Scoped to records whose patch actually renamed something, mirroring
        // the hash check, which only refuses when the sections it would put
        // back have moved. Every record carries a `previousName`, so treating
        // its mere presence as "this edit owns the name" would make a manual
        // rename block the undo of an unrelated reps change.
        let patchRenamedRoutine = record.previousName != nil && record.previousName != record.routineName
        if !allowingOverwrite,
           patchRenamedRoutine,
           current.name != record.routineName {
            return .failure(.routineChangedSinceEdit(current.name))
        }

        // Same graft rule as apply: sections, and the name only where this
        // edit is what changed it. State such as the current phase keeps
        // whatever it is now. Undoing a reps change must leave a name the
        // user has since typed themselves exactly where it is.
        var restored = current
        restored.sections = record.previousSections
        if patchRenamedRoutine, let previousName = record.previousName {
            restored.name = previousName
        }
        routines[index] = restored
        if case .failure(let error) = save() {
            routines[index] = current
            return .failure(.persistenceFailed(error.localizedDescription))
        }
        if let editHistory,
           case .failure(let error) = editHistory.markRestored(record.id) {
            routines[index] = current
            let rollback = save()
            let suffix: String
            if case .failure(let rollbackError) = rollback {
                routines[index] = restored
                suffix = " The routine file changed, and rollback also failed: \(rollbackError.localizedDescription)"
            } else {
                suffix = " The routine file was restored to its previous contents."
            }
            return .failure(.persistenceFailed("Could not update coach edit history: \(error.localizedDescription).\(suffix)"))
        }
        return .success(restored)
    }

    /// Undoes a create by removing the routine it added.
    ///
    /// Returns the routine as it was at the moment it was removed, so the
    /// caller can name what went, which is the same contract the ordinary
    /// restore has: what the routine looks like now that the edit is undone.
    private func removeCreatedRoutine(
        at index: Int,
        record: CoachEditRecord
    ) -> Result<Routine, CoachEditRestoreError> {
        let removed = routines[index]
        routines.remove(at: index)
        if case .failure(let error) = save() {
            routines.insert(removed, at: index)
            return .failure(.persistenceFailed(error.localizedDescription))
        }
        if let editHistory,
           case .failure(let error) = editHistory.markRestored(record.id) {
            routines.insert(removed, at: index)
            let rollback = save()
            let suffix: String
            if case .failure(let rollbackError) = rollback {
                routines.remove(at: index)
                suffix = " The routine file changed, and rollback also failed: \(rollbackError.localizedDescription)"
            } else {
                suffix = " The routine was put back."
            }
            return .failure(.persistenceFailed("Could not update coach edit history: \(error.localizedDescription).\(suffix)"))
        }
        return .success(removed)
    }

    enum ImportError: LocalizedError {
        case invalidJSON
        case decodingFailed(String)
        case looksLikeCoachPatch
        case looksLikeCoachContext
        case outOfBounds(String)
        case persistenceFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON: return "Clipboard does not contain valid text."
            case .decodingFailed(let msg): return "Could not parse routine: \(msg)"
            case .looksLikeCoachPatch:
                return "This looks like a Flow Coach routine patch. Open Flow Coach to preview and apply it instead."
            case .looksLikeCoachContext:
                return "This is the coach context export, not a routine. Paste a single routine's JSON instead."
            case .outOfBounds(let problem):
                return "Not imported: \(problem)."
            case .persistenceFailed(let message):
                return "The imported routine was not saved: \(message)"
            }
        }
    }

    // MARK: - Seed Data
    //
    // Source of truth: "Training Plan - Summer Arc.md" (Obsidian / Fitness folder).
    // Only the two upper/core strength sessions are seeded here.

    static func seedRoutines() -> [Routine] {
        seedRoutineJSON.compactMap(decodeSeedRoutine)
    }

    private func migrateSeedRoutinesIfNeeded() {
        let appliedVersion = defaults.string(forKey: Self.seedVersionKey)

        if case .failed = loadResult {
            return
        }

        if case .missing = loadResult {
            routines = Self.seedRoutines()
            save()
            defaults.set(Self.seedVersion, forKey: Self.seedVersionKey)
            return
        }

        guard appliedVersion != Self.seedVersion else {
            return
        }

        if Self.matchesLegacySeedRoutines(routines) {
            routines = Self.seedRoutines()
            save()
        }

        defaults.set(Self.seedVersion, forKey: Self.seedVersionKey)
    }

    private func preserveCorruptFile() {
        let backupName = "routines.corrupt-\(Int(Date().timeIntervalSince1970)).json"
        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(backupName)
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
    }

    private static func matchesLegacySeedRoutines(_ routines: [Routine]) -> Bool {
        let winterStrengthNames: Set<String> = [
            "Upper A — Push and Row",
            "Lower A — Squat and Hinge",
            "Upper B — Shoulder and Pull",
            "Lower B — Unilateral and Posterior Chain",
        ]
        let summerMaintenanceNames: Set<String> = [
            "Wednesday — Lower Maintenance",
            "Sunday — Upper Maintenance",
        ]
        let currentSeedNames = Set(seedRoutines().map(\.name))

        let routineNames = Set(routines.map(\.name))
        return routineNames == winterStrengthNames
            || routineNames == summerMaintenanceNames
            || routineNames == currentSeedNames
    }

    private static func decodeSeedRoutine(_ json: String) -> Routine? {
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(Routine.self, from: data)
        } catch {
            let message = "Failed to decode seed routine JSON: \(error)"
            print(message)
            assertionFailure(message)
            return nil
        }
    }

    private static let seedRoutineJSON = [
        """
        {
          "id": "D0B696CE-2C78-42E8-9D61-E5DDDD0E0528",
          "name": "Wednesday — Upper A",
          "currentPhase": "base",
          "sections": [
            {
              "id": "973249E6-0B69-4C36-9897-7A7DAD5CBA33",
              "name": "Main Lifts",
              "exercises": [
                {
                  "id": "5DE92253-C398-466D-A67E-DC7C7FE4EA8E",
                  "name": "Floor press KB (24kg)",
                  "sets": 3,
                  "reps": 10,
                  "restBetweenSetsSeconds": 90,
                  "restAfterExerciseSeconds": 90,
                  "notes": "Two-handed grip. Slow lower, firm press.",
                  "perSide": false,
                  "phaseOverrides": {
                    "peak": { "sets": 4, "reps": 10 },
                    "deload": { "sets": 2, "reps": 10 }
                  }
                },
                {
                  "id": "29B65520-959D-4D99-81B8-E79330CC07D9",
                  "name": "Single-arm KB row (24kg)",
                  "sets": 4,
                  "reps": 8,
                  "restBetweenSetsSeconds": 90,
                  "restAfterExerciseSeconds": 90,
                  "notes": "Brace hard, pull elbow to hip, pause.",
                  "perSide": true,
                  "phaseOverrides": {
                    "peak": { "sets": 4, "reps": 10 },
                    "deload": { "sets": 2, "reps": 8 }
                  }
                }
              ]
            },
            {
              "id": "C989F78C-F640-4E06-AC2B-163219131090",
              "name": "Volume Work",
              "exercises": [
                {
                  "id": "1132DAC5-77FE-4FD6-89A2-F078F48B922C",
                  "name": "Push-ups",
                  "sets": 3,
                  "reps": 12,
                  "restBetweenSetsSeconds": 60,
                  "restAfterExerciseSeconds": 90,
                  "notes": "Full range, no collapsed hips, no rushing.",
                  "perSide": false,
                  "phaseOverrides": {
                    "peak": { "sets": 3, "reps": 15 },
                    "deload": { "sets": 2, "reps": 10 }
                  }
                },
                {
                  "id": "A1396A2F-137D-4F3A-827F-30C5CD48DC23",
                  "name": "Standing single-arm KB press (14kg)",
                  "sets": 3,
                  "reps": 6,
                  "restBetweenSetsSeconds": 90,
                  "restAfterExerciseSeconds": 90,
                  "notes": "Strict press, ribs down.",
                  "perSide": true,
                  "phaseOverrides": {
                    "peak": { "sets": 4, "reps": 6 },
                    "deload": { "sets": 2, "reps": 6 }
                  }
                },
                {
                  "id": "0061521C-7917-4127-985B-E818815A95BC",
                  "name": "Dumbbell lateral raises (5kg)",
                  "sets": 3,
                  "reps": 10,
                  "restBetweenSetsSeconds": 60,
                  "restAfterExerciseSeconds": 90,
                  "notes": "Controlled partial range is fine.",
                  "perSide": false,
                  "phaseOverrides": {
                    "peak": { "sets": 3, "reps": 12 },
                    "deload": { "sets": 2, "reps": 8 }
                  }
                }
              ]
            },
            {
              "id": "972D83DA-BD06-4C58-80B2-77F74E5C8F58",
              "name": "Core",
              "exercises": [
                {
                  "id": "9FB9E3F9-C0B2-4D09-B2F6-8841D56FD75B",
                  "name": "Front plank",
                  "sets": 3,
                  "reps": 30,
                  "durationSeconds": 30,
                  "restBetweenSetsSeconds": 30,
                  "restAfterExerciseSeconds": 30,
                  "notes": "Clean timed hold.",
                  "perSide": false,
                  "phaseOverrides": {
                    "peak": { "sets": 3, "reps": 40, "durationSeconds": 40 },
                    "deload": { "sets": 2, "reps": 20, "durationSeconds": 20 }
                  }
                },
                {
                  "id": "F1FE31F6-8C42-4917-8513-AC7E397D5222",
                  "name": "Sit-ups",
                  "sets": 2,
                  "reps": 12,
                  "restBetweenSetsSeconds": 30,
                  "restAfterExerciseSeconds": 30,
                  "notes": "Core finisher.",
                  "perSide": false,
                  "phaseOverrides": {
                    "peak": { "sets": 3, "reps": 15 },
                    "deload": { "sets": 1, "reps": 10 }
                  }
                }
              ]
            }
          ]
        }
        """,
        """
        {
          "id": "06940654-EBF8-4DAE-BA89-BFA4D0099837",
          "name": "Sunday — Upper B",
          "currentPhase": "base",
          "sections": [
            {
              "id": "2277DAE0-709D-4715-B383-C4AB9D8F5637",
              "name": "Main Lifts",
              "exercises": [
                {
                  "id": "53B80CDA-0B9B-41D8-B84D-40D13FC89F34",
                  "name": "Single-arm KB row (24kg)",
                  "sets": 3,
                  "reps": 10,
                  "restBetweenSetsSeconds": 90,
                  "restAfterExerciseSeconds": 90,
                  "notes": "Rows appear twice per week to keep pulling volume honest.",
                  "perSide": true,
                  "phaseOverrides": {
                    "peak": { "sets": 4, "reps": 10 },
                    "deload": { "sets": 2, "reps": 10 }
                  }
                },
                {
                  "id": "7FE7B400-1438-4C45-AFBC-E0CDE4CE9381",
                  "name": "Standing single-arm KB press (14kg)",
                  "sets": 3,
                  "reps": 6,
                  "restBetweenSetsSeconds": 90,
                  "restAfterExerciseSeconds": 90,
                  "notes": "Keep this strict after Saturday's run.",
                  "perSide": true,
                  "phaseOverrides": {
                    "peak": { "sets": 4, "reps": 6 },
                    "deload": { "sets": 2, "reps": 6 }
                  }
                }
              ]
            },
            {
              "id": "9237EFF8-4215-4369-9C0D-0284838DB55B",
              "name": "Volume Work",
              "exercises": [
                {
                  "id": "1BA45E97-C6A0-43B7-85D9-C51D3DC8E5C0",
                  "name": "Chair dips",
                  "sets": 3,
                  "reps": 12,
                  "restBetweenSetsSeconds": 60,
                  "restAfterExerciseSeconds": 90,
                  "notes": "Use a stable setup. Stop if shoulders complain.",
                  "perSide": false,
                  "phaseOverrides": {
                    "peak": { "sets": 3, "reps": 15 },
                    "deload": { "sets": 2, "reps": 8 }
                  }
                },
                {
                  "id": "6B69DCE0-E65F-4926-B824-38D52F47E615",
                  "name": "KB horn-grip curls (14kg)",
                  "sets": 3,
                  "reps": 10,
                  "restBetweenSetsSeconds": 60,
                  "restAfterExerciseSeconds": 90,
                  "notes": "Grip the horns, elbows tucked, slow lower.",
                  "perSide": false,
                  "phaseOverrides": {
                    "peak": { "sets": 3, "reps": 12 },
                    "deload": { "sets": 2, "reps": 8 }
                  }
                },
                {
                  "id": "01193F7F-739D-4148-838E-8EB9E5C792CE",
                  "name": "KB halos (14kg)",
                  "sets": 3,
                  "reps": 10,
                  "restBetweenSetsSeconds": 60,
                  "restAfterExerciseSeconds": 90,
                  "notes": "Smooth circles, close around the head, ribs down.",
                  "perSide": true,
                  "phaseOverrides": {
                    "peak": { "sets": 3, "reps": 12 },
                    "deload": { "sets": 2, "reps": 8 }
                  }
                }
              ]
            },
            {
              "id": "51439711-EC87-4A4B-9F28-3A86C04950A7",
              "name": "Core",
              "exercises": [
                {
                  "id": "2DD274DA-CF10-45AA-97A5-4191A35A8EF3",
                  "name": "Leg raises",
                  "sets": 3,
                  "reps": 10,
                  "restBetweenSetsSeconds": 45,
                  "restAfterExerciseSeconds": 60,
                  "notes": "Controlled lower.",
                  "perSide": false,
                  "phaseOverrides": {
                    "peak": { "sets": 3, "reps": 12 },
                    "deload": { "sets": 2, "reps": 8 }
                  }
                },
                {
                  "id": "393D926D-B9C5-40A4-97E8-7E631650A9C4",
                  "name": "Side plank",
                  "sets": 2,
                  "reps": 30,
                  "durationSeconds": 30,
                  "restBetweenSetsSeconds": 30,
                  "restAfterExerciseSeconds": 30,
                  "notes": "Keep hips stacked.",
                  "perSide": true,
                  "phaseOverrides": {
                    "peak": { "sets": 2, "reps": 40, "durationSeconds": 40 },
                    "deload": { "sets": 1, "reps": 20, "durationSeconds": 20 }
                  }
                }
              ]
            }
          ]
        }
        """
    ]
}
