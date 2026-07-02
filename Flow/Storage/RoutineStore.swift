import Foundation

@Observable
class RoutineStore {
    var routines: [Routine] = []
    var loadError: String?
    private(set) var lastCoachPatchBackup: Routine?
    private static let seedVersion = "summer-arc-upper-core-v2"
    private static let seedVersionKey = "RoutineStore.seedVersion"

    private enum LoadResult {
        case missing
        case loaded
        case failed(Error)
    }

    private let fileURL: URL
    private let defaults: UserDefaults
    private var loadResult: LoadResult = .missing

    init(fileURL: URL? = nil, defaults: UserDefaults = .standard) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.fileURL = docs.appendingPathComponent("routines.json")
        }
        self.defaults = defaults
        loadResult = loadFromDisk()
        migrateSeedRoutinesIfNeeded()
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(routines)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save routines: \(error)")
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

    func addRoutine(_ routine: Routine) {
        routines.append(routine)
        save()
    }

    func updateRoutine(_ routine: Routine) {
        if let idx = routines.firstIndex(where: { $0.id == routine.id }) {
            routines[idx] = routine
            save()
        }
    }

    func deleteRoutine(at offsets: IndexSet) {
        routines.remove(atOffsets: offsets)
        save()
    }

    func exportRoutineJSON(_ routine: Routine) -> String? {
        guard let data = try? FlowRoutineExchange.encoder().encode(routine) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func importRoutineFromJSON(_ json: String) -> Result<Routine, ImportError> {
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
            // Assign new IDs so imports never collide with existing routines
            routine.id = UUID()
            for si in routine.sections.indices {
                routine.sections[si].id = UUID()
                for ei in routine.sections[si].exercises.indices {
                    routine.sections[si].exercises[ei].id = UUID()
                }
            }
            routines.append(routine)
            save()
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

    func applyRoutinePatchPreview(_ preview: FlowRoutinePatchPreview) -> Result<Routine, FlowRoutinePatchError> {
        guard let index = routines.firstIndex(where: { $0.id == preview.patch.routineId }) else {
            return .failure(.routineNotFound(preview.patch.routineId))
        }

        let current = routines[index]
        let currentHash = FlowRoutineRevision.contentHash(for: current)
        guard currentHash == preview.patch.baseContentHash else {
            return .failure(.staleRoutine(expected: preview.patch.baseContentHash, actual: currentHash))
        }

        lastCoachPatchBackup = current
        // Graft the patched structure onto the current routine rather than
        // replacing it wholesale: non-structural state such as currentPhase
        // may have changed since the preview was built (the content hash
        // deliberately ignores it), and applying a patch must not revert
        // that state. Patch operations only ever edit sections.
        var updated = current
        updated.sections = preview.updatedRoutine.sections
        routines[index] = updated
        save()
        return .success(updated)
    }

    func restoreLastCoachPatchBackup() -> Routine? {
        guard let backup = lastCoachPatchBackup else { return nil }
        guard let index = routines.firstIndex(where: { $0.id == backup.id }) else { return nil }
        routines[index] = backup
        lastCoachPatchBackup = nil
        save()
        return backup
    }

    enum ImportError: LocalizedError {
        case invalidJSON
        case decodingFailed(String)
        case looksLikeCoachPatch
        case looksLikeCoachContext

        var errorDescription: String? {
            switch self {
            case .invalidJSON: return "Clipboard does not contain valid text."
            case .decodingFailed(let msg): return "Could not parse routine: \(msg)"
            case .looksLikeCoachPatch:
                return "This looks like a Flow Coach routine patch. Open Flow Coach to preview and apply it instead."
            case .looksLikeCoachContext:
                return "This is the coach context export, not a routine. Paste a single routine's JSON instead."
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
