import Foundation

struct FlowRoutinePatch: Codable, Equatable {
    let schemaVersion: Int
    let routineId: UUID
    let baseRoutineHash: String
    let exportedAt: Date?
    let rationale: String
    let operations: [FlowRoutinePatchOperation]
}

struct FlowRoutinePatchOperation: Codable, Equatable {
    var kind: Kind
    var exerciseId: UUID? = nil
    var sectionId: UUID? = nil
    var targetSectionId: UUID? = nil
    var afterExerciseId: UUID? = nil
    var phase: WorkoutPhase? = nil
    var expectedIntValue: Int? = nil
    var newIntValue: Int? = nil
    var expectedStringValue: String? = nil
    var newStringValue: String? = nil
    var expectedPhaseOverride: PhaseOverride? = nil
    var newPhaseOverride: PhaseOverride? = nil
    var removePhaseOverride: Bool? = nil
    var exercise: ExerciseBlock? = nil

    enum Kind: String, Codable, Equatable {
        case replaceExerciseReps
        case replaceExerciseSets
        case replaceTimedDuration
        case replaceRestBetweenSets
        case replaceRestAfterExercise
        case updateExerciseNotes
        case addExercise
        case removeExercise
        case moveExercise
        case replacePhaseOverride
    }
}

struct FlowRoutinePatchPreview {
    let patch: FlowRoutinePatch
    let originalRoutine: Routine
    let updatedRoutine: Routine
    let diffs: [FlowRoutinePatchDiff]
}

struct FlowRoutinePatchDiff: Identifiable, Equatable {
    let operationIndex: Int
    let title: String
    let before: String
    let after: String

    var id: String {
        "\(operationIndex)-\(title)-\(before)-\(after)"
    }
}

enum FlowRoutinePatchError: LocalizedError, Equatable {
    case invalidJSON(String)
    case unsupportedSchema(Int)
    case missingField(String)
    case routineNotFound(UUID)
    case staleRoutine(expected: String, actual: String)
    case exerciseNotFound(UUID)
    case sectionNotFound(UUID)
    case duplicateExerciseId(UUID)
    case beforeValueMismatch(field: String, expected: String, actual: String)
    case invalidValue(field: String, message: String)
    case noOperations
    case wouldEmptyRoutine

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let message):
            return "Could not parse routine patch: \(message)"
        case .unsupportedSchema(let version):
            return "Unsupported routine patch schema version \(version)."
        case .missingField(let field):
            return "Routine patch is missing \(field)."
        case .routineNotFound(let id):
            return "No saved routine matches \(id.uuidString)."
        case .staleRoutine(let expected, let actual):
            return "Patch is stale. Expected routine hash \(expected), but current hash is \(actual)."
        case .exerciseNotFound(let id):
            return "No exercise matches \(id.uuidString)."
        case .sectionNotFound(let id):
            return "No section matches \(id.uuidString)."
        case .duplicateExerciseId(let id):
            return "Exercise id \(id.uuidString) already exists in this routine."
        case .beforeValueMismatch(let field, let expected, let actual):
            return "\(field) changed before import. Expected \(expected), found \(actual)."
        case .invalidValue(let field, let message):
            return "\(field) is invalid: \(message)"
        case .noOperations:
            return "Routine patch does not include any operations."
        case .wouldEmptyRoutine:
            return "Routine patch would leave the routine empty."
        }
    }
}

enum FlowRoutineRevision {
    static func hash(for routine: Routine) -> String {
        let encoder = FlowCoachCoding.encoder()
        guard let data = try? encoder.encode(routine) else { return "unhashable" }
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(format: "%016llx", hash)
    }
}

enum FlowRoutinePatcher {
    static func preview(json: String, routines: [Routine]) throws -> FlowRoutinePatchPreview {
        let cleaned = sanitizedPatchJSON(from: json)
        guard let data = cleaned.data(using: .utf8) else {
            throw FlowRoutinePatchError.invalidJSON("Patch text is not valid UTF-8.")
        }

        let patch: FlowRoutinePatch
        do {
            patch = try FlowCoachCoding.decoder().decode(FlowRoutinePatch.self, from: data)
        } catch {
            throw FlowRoutinePatchError.invalidJSON(error.localizedDescription)
        }

        return try preview(patch: patch, routines: routines)
    }

    /// Extracts the patch JSON object from pasted text that may be wrapped in
    /// Markdown code fences (```json … ```) or surrounded by assistant prose,
    /// which chat models routinely add. Strips to the outermost `{ … }` span.
    /// Already-clean JSON is returned unchanged (only trimmed).
    ///
    /// Note: this is a deliberately simple outermost-brace extraction. It does
    /// not parse multiple JSON blocks or braces embedded in surrounding prose;
    /// a malformed remainder still fails in `decode` with the original error path.
    static func sanitizedPatchJSON(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstBrace = trimmed.firstIndex(of: "{"),
              let lastBrace = trimmed.lastIndex(of: "}"),
              firstBrace < lastBrace else {
            return trimmed
        }
        return String(trimmed[firstBrace...lastBrace])
    }

    static func preview(patch: FlowRoutinePatch, routines: [Routine]) throws -> FlowRoutinePatchPreview {
        guard patch.schemaVersion == 1 else {
            throw FlowRoutinePatchError.unsupportedSchema(patch.schemaVersion)
        }
        guard !patch.operations.isEmpty else {
            throw FlowRoutinePatchError.noOperations
        }
        guard let routine = routines.first(where: { $0.id == patch.routineId }) else {
            throw FlowRoutinePatchError.routineNotFound(patch.routineId)
        }

        let actualHash = FlowRoutineRevision.hash(for: routine)
        guard actualHash == patch.baseRoutineHash else {
            throw FlowRoutinePatchError.staleRoutine(expected: patch.baseRoutineHash, actual: actualHash)
        }

        var updated = routine
        var diffs: [FlowRoutinePatchDiff] = []
        for (offset, operation) in patch.operations.enumerated() {
            let diff = try apply(operation, operationIndex: offset + 1, to: &updated)
            diffs.append(diff)
        }

        guard updated.canStartWorkout else {
            throw FlowRoutinePatchError.wouldEmptyRoutine
        }

        return FlowRoutinePatchPreview(
            patch: patch,
            originalRoutine: routine,
            updatedRoutine: updated,
            diffs: diffs
        )
    }

    private static func apply(
        _ operation: FlowRoutinePatchOperation,
        operationIndex: Int,
        to routine: inout Routine
    ) throws -> FlowRoutinePatchDiff {
        switch operation.kind {
        case .replaceExerciseReps:
            let value = try requireInt(operation.newIntValue, "newIntValue")
            try validate(value, field: "reps", range: 1...100)
            let location = try exerciseLocation(in: routine, id: try requireUUID(operation.exerciseId, "exerciseId"))
            var exercise = routine.sections[location.sectionIndex].exercises[location.exerciseIndex]
            guard exercise.durationSeconds == nil else {
                throw FlowRoutinePatchError.invalidValue(
                    field: "replaceExerciseReps",
                    message: "use replaceTimedDuration for timed exercises"
                )
            }
            try expectInt(operation.expectedIntValue, actual: exercise.reps, field: "\(exercise.name) reps")
            let before = "\(exercise.name): \(exercise.reps) reps"
            exercise.reps = value
            routine.sections[location.sectionIndex].exercises[location.exerciseIndex] = exercise
            return FlowRoutinePatchDiff(
                operationIndex: operationIndex,
                title: "Replace reps",
                before: before,
                after: "\(exercise.name): \(value) reps"
            )

        case .replaceExerciseSets:
            let value = try requireInt(operation.newIntValue, "newIntValue")
            try validate(value, field: "sets", range: 1...10)
            let location = try exerciseLocation(in: routine, id: try requireUUID(operation.exerciseId, "exerciseId"))
            var exercise = routine.sections[location.sectionIndex].exercises[location.exerciseIndex]
            try expectInt(operation.expectedIntValue, actual: exercise.sets, field: "\(exercise.name) sets")
            let before = "\(exercise.name): \(exercise.sets) sets"
            exercise.sets = value
            routine.sections[location.sectionIndex].exercises[location.exerciseIndex] = exercise
            return FlowRoutinePatchDiff(
                operationIndex: operationIndex,
                title: "Replace sets",
                before: before,
                after: "\(exercise.name): \(value) sets"
            )

        case .replaceTimedDuration:
            let value = try requireInt(operation.newIntValue, "newIntValue")
            try validate(value, field: "durationSeconds", range: 1...3600)
            let location = try exerciseLocation(in: routine, id: try requireUUID(operation.exerciseId, "exerciseId"))
            var exercise = routine.sections[location.sectionIndex].exercises[location.exerciseIndex]
            guard let current = exercise.durationSeconds else {
                throw FlowRoutinePatchError.invalidValue(field: "durationSeconds", message: "exercise is not timed")
            }
            try expectInt(operation.expectedIntValue, actual: current, field: "\(exercise.name) durationSeconds")
            let before = "\(exercise.name): \(current)s"
            exercise.durationSeconds = value
            routine.sections[location.sectionIndex].exercises[location.exerciseIndex] = exercise
            return FlowRoutinePatchDiff(
                operationIndex: operationIndex,
                title: "Replace timed duration",
                before: before,
                after: "\(exercise.name): \(value)s"
            )

        case .replaceRestBetweenSets:
            return try replaceRest(
                operation,
                operationIndex: operationIndex,
                fieldName: "restBetweenSetsSeconds",
                current: { $0.restBetweenSetsSeconds },
                set: { $0.restBetweenSetsSeconds = $1 },
                in: &routine
            )

        case .replaceRestAfterExercise:
            return try replaceRest(
                operation,
                operationIndex: operationIndex,
                fieldName: "restAfterExerciseSeconds",
                current: { $0.restAfterExerciseSeconds },
                set: { $0.restAfterExerciseSeconds = $1 },
                in: &routine
            )

        case .updateExerciseNotes:
            let value = try requireString(operation.newStringValue, "newStringValue")
            guard value.count <= 500 else {
                throw FlowRoutinePatchError.invalidValue(field: "notes", message: "must be 500 characters or fewer")
            }
            let location = try exerciseLocation(in: routine, id: try requireUUID(operation.exerciseId, "exerciseId"))
            var exercise = routine.sections[location.sectionIndex].exercises[location.exerciseIndex]
            try expectString(operation.expectedStringValue, actual: exercise.notes, field: "\(exercise.name) notes")
            let before = exercise.notes.isEmpty ? "\(exercise.name): [no notes]" : "\(exercise.name): \(exercise.notes)"
            exercise.notes = value
            routine.sections[location.sectionIndex].exercises[location.exerciseIndex] = exercise
            return FlowRoutinePatchDiff(
                operationIndex: operationIndex,
                title: "Update notes",
                before: before,
                after: value.isEmpty ? "\(exercise.name): [no notes]" : "\(exercise.name): \(value)"
            )

        case .addExercise:
            let sectionId = try requireUUID(operation.sectionId, "sectionId")
            let sectionIndex = try sectionIndex(in: routine, id: sectionId)
            var exercise = try requireExercise(operation.exercise, "exercise")
            exercise.phaseOverrides = exercise.phaseOverrides.filter { !$0.value.isEmpty }
            try validateExercise(exercise)
            guard findExercise(in: routine, id: exercise.id) == nil else {
                throw FlowRoutinePatchError.duplicateExerciseId(exercise.id)
            }
            let insertIndex: Int
            if let afterExerciseId = operation.afterExerciseId {
                let after = try exerciseLocation(in: routine, id: afterExerciseId)
                guard routine.sections[after.sectionIndex].id == sectionId else {
                    throw FlowRoutinePatchError.invalidValue(
                        field: "afterExerciseId",
                        message: "must identify an exercise in the target section"
                    )
                }
                insertIndex = after.exerciseIndex + 1
            } else {
                insertIndex = routine.sections[sectionIndex].exercises.count
            }
            routine.sections[sectionIndex].exercises.insert(exercise, at: insertIndex)
            return FlowRoutinePatchDiff(
                operationIndex: operationIndex,
                title: "Add exercise",
                before: "\(routine.sections[sectionIndex].name): [not present]",
                after: "\(routine.sections[sectionIndex].name): \(exercise.name)"
            )

        case .removeExercise:
            let id = try requireUUID(operation.exerciseId, "exerciseId")
            let location = try exerciseLocation(in: routine, id: id)
            let exercise = routine.sections[location.sectionIndex].exercises[location.exerciseIndex]
            try expectString(operation.expectedStringValue, actual: exercise.name, field: "exercise name")
            routine.sections[location.sectionIndex].exercises.remove(at: location.exerciseIndex)
            return FlowRoutinePatchDiff(
                operationIndex: operationIndex,
                title: "Remove exercise",
                before: exercise.name,
                after: "[removed]"
            )

        case .moveExercise:
            let id = try requireUUID(operation.exerciseId, "exerciseId")
            let targetSectionId = try requireUUID(operation.targetSectionId, "targetSectionId")
            let source = try exerciseLocation(in: routine, id: id)
            let moving = routine.sections[source.sectionIndex].exercises.remove(at: source.exerciseIndex)
            let targetSectionIndex = try sectionIndex(in: routine, id: targetSectionId)
            let insertIndex: Int
            if let afterExerciseId = operation.afterExerciseId {
                let after = try exerciseLocation(in: routine, id: afterExerciseId)
                guard routine.sections[after.sectionIndex].id == targetSectionId else {
                    throw FlowRoutinePatchError.invalidValue(
                        field: "afterExerciseId",
                        message: "must identify an exercise in the target section"
                    )
                }
                insertIndex = after.exerciseIndex + 1
            } else {
                insertIndex = routine.sections[targetSectionIndex].exercises.count
            }
            routine.sections[targetSectionIndex].exercises.insert(moving, at: insertIndex)
            return FlowRoutinePatchDiff(
                operationIndex: operationIndex,
                title: "Move exercise",
                before: "\(routine.sections[source.sectionIndex].name): \(moving.name)",
                after: "\(routine.sections[targetSectionIndex].name): \(moving.name)"
            )

        case .replacePhaseOverride:
            let phase = try requirePhase(operation.phase)
            guard phase != .base else {
                throw FlowRoutinePatchError.invalidValue(field: "phase", message: "base does not use phase overrides")
            }
            let location = try exerciseLocation(in: routine, id: try requireUUID(operation.exerciseId, "exerciseId"))
            var exercise = routine.sections[location.sectionIndex].exercises[location.exerciseIndex]
            let current = exercise.phaseOverrides[phase]
            guard current == operation.expectedPhaseOverride else {
                throw FlowRoutinePatchError.beforeValueMismatch(
                    field: "\(exercise.name) \(phase.rawValue) override",
                    expected: format(operation.expectedPhaseOverride),
                    actual: format(current)
                )
            }
            if operation.removePhaseOverride == true {
                exercise.phaseOverrides.removeValue(forKey: phase)
            } else {
                guard let override = operation.newPhaseOverride else {
                    throw FlowRoutinePatchError.missingField("newPhaseOverride")
                }
                try validatePhaseOverride(override)
                if override.isEmpty {
                    exercise.phaseOverrides.removeValue(forKey: phase)
                } else {
                    exercise.phaseOverrides[phase] = override
                }
            }
            routine.sections[location.sectionIndex].exercises[location.exerciseIndex] = exercise
            return FlowRoutinePatchDiff(
                operationIndex: operationIndex,
                title: "Replace \(phase.displayName) override",
                before: "\(exercise.name): \(format(current))",
                after: "\(exercise.name): \(format(exercise.phaseOverrides[phase]))"
            )
        }
    }

    private static func replaceRest(
        _ operation: FlowRoutinePatchOperation,
        operationIndex: Int,
        fieldName: String,
        current: (ExerciseBlock) -> Int,
        set: (inout ExerciseBlock, Int) -> Void,
        in routine: inout Routine
    ) throws -> FlowRoutinePatchDiff {
        let value = try requireInt(operation.newIntValue, "newIntValue")
        try validate(value, field: fieldName, range: 0...900)
        let location = try exerciseLocation(in: routine, id: try requireUUID(operation.exerciseId, "exerciseId"))
        var exercise = routine.sections[location.sectionIndex].exercises[location.exerciseIndex]
        let actual = current(exercise)
        try expectInt(operation.expectedIntValue, actual: actual, field: "\(exercise.name) \(fieldName)")
        set(&exercise, value)
        routine.sections[location.sectionIndex].exercises[location.exerciseIndex] = exercise
        return FlowRoutinePatchDiff(
            operationIndex: operationIndex,
            title: "Replace rest",
            before: "\(exercise.name): \(fieldName) \(actual)s",
            after: "\(exercise.name): \(fieldName) \(value)s"
        )
    }

    private static func requireUUID(_ value: UUID?, _ field: String) throws -> UUID {
        guard let value else { throw FlowRoutinePatchError.missingField(field) }
        return value
    }

    private static func requireInt(_ value: Int?, _ field: String) throws -> Int {
        guard let value else { throw FlowRoutinePatchError.missingField(field) }
        return value
    }

    private static func requireString(_ value: String?, _ field: String) throws -> String {
        guard let value else { throw FlowRoutinePatchError.missingField(field) }
        return value
    }

    private static func requireExercise(_ value: ExerciseBlock?, _ field: String) throws -> ExerciseBlock {
        guard let value else { throw FlowRoutinePatchError.missingField(field) }
        return value
    }

    private static func requirePhase(_ value: WorkoutPhase?) throws -> WorkoutPhase {
        guard let value else { throw FlowRoutinePatchError.missingField("phase") }
        return value
    }

    private static func expectInt(_ expected: Int?, actual: Int, field: String) throws {
        guard let expected else { throw FlowRoutinePatchError.missingField("expectedIntValue") }
        guard expected == actual else {
            throw FlowRoutinePatchError.beforeValueMismatch(
                field: field,
                expected: "\(expected)",
                actual: "\(actual)"
            )
        }
    }

    private static func expectString(_ expected: String?, actual: String, field: String) throws {
        guard let expected else { throw FlowRoutinePatchError.missingField("expectedStringValue") }
        guard expected == actual else {
            throw FlowRoutinePatchError.beforeValueMismatch(field: field, expected: expected, actual: actual)
        }
    }

    private static func validate(_ value: Int, field: String, range: ClosedRange<Int>) throws {
        guard range.contains(value) else {
            throw FlowRoutinePatchError.invalidValue(field: field, message: "must be between \(range.lowerBound) and \(range.upperBound)")
        }
    }

    private static func validateExercise(_ exercise: ExerciseBlock) throws {
        guard !exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FlowRoutinePatchError.invalidValue(field: "exercise.name", message: "must not be empty")
        }
        try validate(exercise.sets, field: "exercise.sets", range: 1...10)
        try validate(exercise.reps, field: "exercise.reps", range: 1...100)
        if let duration = exercise.durationSeconds {
            try validate(duration, field: "exercise.durationSeconds", range: 1...3600)
        }
        try validate(exercise.restBetweenSetsSeconds, field: "exercise.restBetweenSetsSeconds", range: 0...900)
        try validate(exercise.restAfterExerciseSeconds, field: "exercise.restAfterExerciseSeconds", range: 0...900)
        guard exercise.notes.count <= 500 else {
            throw FlowRoutinePatchError.invalidValue(field: "exercise.notes", message: "must be 500 characters or fewer")
        }
        for override in exercise.phaseOverrides.values {
            try validatePhaseOverride(override)
        }
    }

    private static func validatePhaseOverride(_ override: PhaseOverride) throws {
        if let sets = override.sets {
            try validate(sets, field: "phaseOverride.sets", range: 1...10)
        }
        if let reps = override.reps {
            try validate(reps, field: "phaseOverride.reps", range: 1...100)
        }
        if let duration = override.durationSeconds {
            try validate(duration, field: "phaseOverride.durationSeconds", range: 1...3600)
        }
    }

    private static func sectionIndex(in routine: Routine, id: UUID) throws -> Int {
        guard let index = routine.sections.firstIndex(where: { $0.id == id }) else {
            throw FlowRoutinePatchError.sectionNotFound(id)
        }
        return index
    }

    private static func exerciseLocation(in routine: Routine, id: UUID) throws -> (sectionIndex: Int, exerciseIndex: Int) {
        guard let location = findExercise(in: routine, id: id) else {
            throw FlowRoutinePatchError.exerciseNotFound(id)
        }
        return location
    }

    private static func findExercise(in routine: Routine, id: UUID) -> (sectionIndex: Int, exerciseIndex: Int)? {
        for sectionIndex in routine.sections.indices {
            if let exerciseIndex = routine.sections[sectionIndex].exercises.firstIndex(where: { $0.id == id }) {
                return (sectionIndex, exerciseIndex)
            }
        }
        return nil
    }

    private static func format(_ override: PhaseOverride?) -> String {
        guard let override else { return "[none]" }
        var parts: [String] = []
        if let sets = override.sets { parts.append("sets=\(sets)") }
        if let reps = override.reps { parts.append("reps=\(reps)") }
        if let duration = override.durationSeconds { parts.append("durationSeconds=\(duration)") }
        return parts.isEmpty ? "[none]" : parts.joined(separator: " ")
    }
}
