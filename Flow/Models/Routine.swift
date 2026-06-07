import Foundation

enum WorkoutPhase: String, Codable, CaseIterable, Equatable {
    case base
    case peak
    case deload

    var displayName: String {
        switch self {
        case .base: return "Base"
        case .peak: return "Peak"
        case .deload: return "Deload"
        }
    }
}

struct PhaseOverride: Codable, Equatable {
    var sets: Int?
    var reps: Int?
    var durationSeconds: Int?

    init(sets: Int? = nil, reps: Int? = nil, durationSeconds: Int? = nil) {
        self.sets = sets
        self.reps = reps
        self.durationSeconds = durationSeconds
    }

    var isEmpty: Bool {
        sets == nil && reps == nil && durationSeconds == nil
    }
}

struct Routine: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var sections: [Section]
    var currentPhase: WorkoutPhase

    init(id: UUID = UUID(), name: String, sections: [Section] = [], currentPhase: WorkoutPhase = .base) {
        self.id = id
        self.name = name
        self.sections = sections
        self.currentPhase = currentPhase
    }

    enum CodingKeys: String, CodingKey {
        case id, name, sections, currentPhase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sections = try c.decode([Section].self, forKey: .sections)
        currentPhase = try c.decodeIfPresent(WorkoutPhase.self, forKey: .currentPhase) ?? .base
    }
}

struct Section: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var exercises: [ExerciseBlock]

    init(id: UUID = UUID(), name: String, exercises: [ExerciseBlock] = []) {
        self.id = id
        self.name = name
        self.exercises = exercises
    }
}

struct ExerciseBlock: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var sets: Int
    var reps: Int
    var durationSeconds: Int?
    var restBetweenSetsSeconds: Int
    var restAfterExerciseSeconds: Int
    var notes: String
    var perSide: Bool
    var phaseOverrides: [WorkoutPhase: PhaseOverride]

    init(
        id: UUID = UUID(),
        name: String,
        sets: Int = 3,
        reps: Int = 10,
        durationSeconds: Int? = nil,
        restBetweenSetsSeconds: Int = 60,
        restAfterExerciseSeconds: Int = 90,
        notes: String = "",
        perSide: Bool = false,
        phaseOverrides: [WorkoutPhase: PhaseOverride] = [:]
    ) {
        self.id = id
        self.name = name
        self.sets = sets
        self.reps = reps
        self.durationSeconds = durationSeconds
        self.restBetweenSetsSeconds = restBetweenSetsSeconds
        self.restAfterExerciseSeconds = restAfterExerciseSeconds
        self.notes = notes
        self.perSide = perSide
        self.phaseOverrides = phaseOverrides
    }

    // Backward-compatible decoding: handles old string reps and single restSeconds
    enum CodingKeys: String, CodingKey {
        case id, name, sets, reps, durationSeconds, restBetweenSetsSeconds, restAfterExerciseSeconds, notes, perSide
        case phaseOverrides
        case restSeconds // legacy key
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sets = try c.decode(Int.self, forKey: .sets)
        notes = try c.decode(String.self, forKey: .notes)
        perSide = try c.decode(Bool.self, forKey: .perSide)

        // Reps: try Int first, fall back to String (take lower bound of range)
        if let intReps = try? c.decode(Int.self, forKey: .reps) {
            reps = intReps
        } else if let strReps = try? c.decode(String.self, forKey: .reps) {
            let digits = strReps.prefix(while: { $0.isNumber })
            reps = Int(digits) ?? 10
        } else {
            reps = 10
        }

        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds)
            ?? Self.legacyDurationSeconds(from: notes, reps: reps)

        // Rest: try new split fields first, fall back to legacy single field
        if let between = try? c.decode(Int.self, forKey: .restBetweenSetsSeconds) {
            restBetweenSetsSeconds = between
            restAfterExerciseSeconds = try c.decodeIfPresent(Int.self, forKey: .restAfterExerciseSeconds) ?? min(between + 30, 180)
        } else if let legacy = try? c.decode(Int.self, forKey: .restSeconds) {
            restBetweenSetsSeconds = legacy
            restAfterExerciseSeconds = legacy == 0 ? 0 : min(legacy + 30, 180)
        } else {
            restBetweenSetsSeconds = 60
            restAfterExerciseSeconds = 90
        }

        // Phase overrides: decode as [String: PhaseOverride], map to enum keys
        if let raw = try c.decodeIfPresent([String: PhaseOverride].self, forKey: .phaseOverrides) {
            var mapped: [WorkoutPhase: PhaseOverride] = [:]
            for (key, value) in raw {
                if let phase = WorkoutPhase(rawValue: key) {
                    mapped[phase] = value
                }
            }
            phaseOverrides = mapped
        } else {
            phaseOverrides = [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(sets, forKey: .sets)
        try c.encode(reps, forKey: .reps)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encode(restBetweenSetsSeconds, forKey: .restBetweenSetsSeconds)
        try c.encode(restAfterExerciseSeconds, forKey: .restAfterExerciseSeconds)
        try c.encode(notes, forKey: .notes)
        try c.encode(perSide, forKey: .perSide)
        if !phaseOverrides.isEmpty {
            let raw = Dictionary(uniqueKeysWithValues: phaseOverrides.map { ($0.key.rawValue, $0.value) })
            try c.encode(raw, forKey: .phaseOverrides)
        }
    }

    var isTimed: Bool {
        workDisplayValue > 0 && durationSeconds != nil
    }

    var workDisplayValue: Int {
        durationSeconds ?? reps
    }

    /// Returns a copy of this block with sets/reps/duration resolved for the given phase.
    /// Base phase returns self unchanged. Missing override fields inherit Base values.
    func resolved(for phase: WorkoutPhase) -> ExerciseBlock {
        guard phase != .base, let override = phaseOverrides[phase] else { return self }
        var copy = self
        if let s = override.sets { copy.sets = s }
        if let r = override.reps { copy.reps = r }
        if let d = override.durationSeconds { copy.durationSeconds = d }
        return copy
    }

    private static func legacyDurationSeconds(from notes: String, reps: Int) -> Int? {
        let normalizedNotes = notes.lowercased()
        guard reps > 0 else { return nil }
        guard normalizedNotes.contains("hold") else { return nil }
        guard normalizedNotes.contains("sec") || normalizedNotes.contains("second") else { return nil }
        return reps
    }
}

// Flattened step for the workout flow
struct WorkoutStep: Identifiable {
    let id = UUID()
    let sectionName: String
    let exercise: ExerciseBlock
    let setNumber: Int
    let isFirstInSection: Bool
    let isLastSetOfExercise: Bool

    var restSeconds: Int {
        isLastSetOfExercise ? exercise.restAfterExerciseSeconds : exercise.restBetweenSetsSeconds
    }

    var workSeconds: Int {
        exercise.durationSeconds ?? 30
    }
}

extension Routine {
    /// Build steps for the routine's currentPhase. Phase values are baked into each step's ExerciseBlock,
    /// so downstream views remain phase-agnostic.
    func buildSteps() -> [WorkoutStep] {
        buildSteps(for: currentPhase)
    }

    func buildSteps(for phase: WorkoutPhase) -> [WorkoutStep] {
        var steps: [WorkoutStep] = []
        for section in sections {
            for (exerciseIndex, exercise) in section.exercises.enumerated() {
                let resolved = exercise.resolved(for: phase)
                for setNum in 1...max(resolved.sets, 1) {
                    steps.append(WorkoutStep(
                        sectionName: section.name,
                        exercise: resolved,
                        setNumber: setNum,
                        isFirstInSection: exerciseIndex == 0 && setNum == 1,
                        isLastSetOfExercise: setNum == resolved.sets
                    ))
                }
            }
        }
        return steps
    }
}
