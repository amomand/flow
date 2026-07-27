import Foundation

struct FlowRoutinePatch: Codable, Equatable {
    /// Schema 2 pins patches to the routine content hash (`c1-…`), so
    /// non-structural state changes such as a phase toggle no longer stale a
    /// patch. Schema 1 pinned `baseRoutineHash` over the whole routine and is
    /// no longer accepted; nothing persists patches yet, so a v1 patch can
    /// only come from a stale chat and the fix is a fresh context export.
    ///
    /// Schema 3 adds operations that change a routine's shape rather than its
    /// numbers, starting with `renameRoutine`. The version is what a patch
    /// declares it is, not the newest one available: a schema 2 patch is still
    /// accepted and still means exactly what it did, and an operation may only
    /// appear in a patch whose declared version knows about it. That rule is
    /// what lets the bridge advertise capabilities honestly, because "schema 2"
    /// names one fixed operation set on both sides.
    static let currentSchemaVersion = 3
    static let supportedSchemaVersions: Set<Int> = [2, 3]

    let schemaVersion: Int
    let routineId: UUID
    let baseContentHash: String
    let exportedAt: Date?
    let rationale: String
    let operations: [FlowRoutinePatchOperation]
}

/// A section arriving with a patch.
///
/// Deliberately not `Section`: a section a patch adds is always empty, and
/// carrying exercises here would be a second way to add them, bypassing the
/// per-exercise validation `addExercise` already does. Fill a new section with
/// `addExercise` operations later in the same patch.
struct FlowRoutinePatchSection: Codable, Equatable {
    let id: UUID
    let name: String
}

struct FlowRoutinePatchOperation: Codable, Equatable {
    var kind: Kind
    var exerciseId: UUID? = nil
    var sectionId: UUID? = nil
    var targetSectionId: UUID? = nil
    var afterSectionId: UUID? = nil
    var afterExerciseId: UUID? = nil
    var section: FlowRoutinePatchSection? = nil
    var phase: WorkoutPhase? = nil
    var expectedIntValue: Int? = nil
    var newIntValue: Int? = nil
    var expectedStringValue: String? = nil
    var newStringValue: String? = nil
    var expectedPhaseOverride: PhaseOverride? = nil
    var newPhaseOverride: PhaseOverride? = nil
    var removePhaseOverride: Bool? = nil
    var exercise: ExerciseBlock? = nil

    enum Kind: String, Codable, Equatable, CaseIterable {
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
        case renameRoutine
        case addSection

        /// The first schema version this operation belongs to. A patch may
        /// only use operations its declared version knows about, so a coach
        /// that was told "this build speaks schema 2" cannot smuggle a newer
        /// operation through under the older version number.
        var minimumSchemaVersion: Int {
            switch self {
            case .renameRoutine, .addSection:
                return 3
            default:
                return 2
            }
        }
    }
}

struct FlowRoutinePatchPreview {
    let patch: FlowRoutinePatch
    let originalRoutine: Routine
    let updatedRoutine: Routine
    let diffs: [FlowRoutinePatchDiff]
    /// The patch's stale `baseContentHash` when the routine changed after the
    /// patch was written but every operation's expected before-value still
    /// matched, so Flow rebased it onto the current content. `nil` when the
    /// patch previewed against the exact content it was written for.
    var rebasedFromHash: String? = nil
}

struct FlowRoutinePatchDiff: Identifiable, Equatable, Codable {
    let operationIndex: Int
    let title: String
    let before: String
    let after: String
    /// Where a base value moved and the exercise carries a phase override for
    /// the same field, the resulting per-phase state (#61). Base operations do
    /// not cascade into overrides, so a one-number diff can hide the fact that
    /// a phase has stopped being a step up. Empty for every other operation,
    /// and for exercises with no override on the field being changed.
    var phaseConsequences: [FlowRoutinePhaseConsequence] = []

    var id: String {
        "\(operationIndex)-\(title)-\(before)-\(after)"
    }

    enum CodingKeys: String, CodingKey {
        case operationIndex, title, before, after, phaseConsequences
    }
}

extension FlowRoutinePatchDiff {
    /// History records written before phase consequences existed have no such
    /// key, and must keep decoding.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationIndex = try container.decode(Int.self, forKey: .operationIndex)
        title = try container.decode(String.self, forKey: .title)
        before = try container.decode(String.self, forKey: .before)
        after = try container.decode(String.self, forKey: .after)
        phaseConsequences = try container.decodeIfPresent(
            [FlowRoutinePhaseConsequence].self,
            forKey: .phaseConsequences
        ) ?? []
    }
}

/// What a base-value change leaves one phase doing (#61).
///
/// Reported, never enforced: a peak that matches base is a legitimate thing to
/// want, and the patch is not wrong for producing it. The person approving just
/// needs to be able to see it.
struct FlowRoutinePhaseConsequence: Identifiable, Equatable, Codable {
    enum Relation: String, Codable {
        /// The override still sits above the new base value.
        case stepsUpFromBase
        case matchesBase
        case belowBase
        /// No override for this field, so the phase takes the new base value.
        case inheritsBase
    }

    /// The field that changed, which is also how it is read out. A deload
    /// override of one set is a real case, so the unit has to agree with the
    /// number rather than always reading "1 sets".
    enum Unit: String, Codable {
        case sets
        case reps
        case seconds

        func label(for value: Int) -> String {
            guard value == 1 else { return rawValue }
            switch self {
            case .sets: return "set"
            case .reps: return "rep"
            case .seconds: return "second"
            }
        }
    }

    let phase: WorkoutPhase
    let unit: Unit
    let baseValue: Int
    let overrideValue: Int?
    let relation: Relation

    var id: String { "\(phase.rawValue)-\(unit.rawValue)" }

    var value: Int { overrideValue ?? baseValue }

    /// Describes the values rather than condemning the patch.
    var summary: String {
        switch relation {
        case .inheritsBase:
            return "\(phase.displayName): follows base at \(baseValue) \(unit.label(for: baseValue))"
        case .stepsUpFromBase:
            return "\(phase.displayName): \(value) \(unit.label(for: value))"
        case .matchesBase:
            return "\(phase.displayName): \(value) \(unit.label(for: value)), the same as base"
        case .belowBase:
            return "\(phase.displayName): \(value) \(unit.label(for: value)), below base at \(baseValue) \(unit.label(for: baseValue))"
        }
    }

    /// The case #61 asks to call out: an override that no longer sits above the
    /// new base value, so the progression has flattened or reversed on this
    /// field.
    var flattensProgression: Bool {
        relation == .matchesBase || relation == .belowBase
    }
}

enum FlowRoutinePatchError: LocalizedError, Equatable {
    case invalidJSON(String)
    case unsupportedSchema(Int)
    case missingField(String)
    case routineNotFound(UUID)
    case staleConflict(operationIndex: Int, reason: String)
    case exerciseNotFound(UUID)
    case sectionNotFound(UUID)
    case duplicateExerciseId(UUID)
    case beforeValueMismatch(field: String, expected: String, actual: String)
    case invalidValue(field: String, message: String)
    case noOperations
    case wouldEmptyRoutine
    case duplicateSectionId(UUID)
    case tooManySections(Int)
    case tooManyExercisesInSection(section: String, limit: Int)
    case operationNeedsNewerSchema(kind: String, minimum: Int, declared: Int)
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let message):
            return "Could not parse routine patch: \(message)"
        case .unsupportedSchema(let version):
            return "Unsupported routine patch schema version \(version). Copy a fresh coach context and ask for a schemaVersion \(FlowRoutinePatch.currentSchemaVersion) patch."
        case .operationNeedsNewerSchema(let kind, let minimum, let declared):
            return "\(kind) was introduced in routine patch schema \(minimum), but this patch declares schema \(declared). Ask the coach for a schemaVersion \(minimum) patch."
        case .missingField(let field):
            return "Routine patch is missing \(field)."
        case .routineNotFound(let id):
            return "No saved routine matches \(id.uuidString)."
        case .staleConflict(let operationIndex, let reason):
            return "The routine changed after this patch was written, and operation \(operationIndex) no longer matches: \(reason) Ask the coach for a fresh patch against a new context export."
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
        case .duplicateSectionId(let id):
            return "Section id \(id.uuidString) already exists in this routine."
        case .tooManySections(let limit):
            return "Routine patch would take the routine past \(limit) sections."
        case .tooManyExercisesInSection(let section, let limit):
            return "Routine patch would take \(section) past \(limit) exercises."
        case .persistenceFailed(let message):
            return "The routine patch was not saved: \(message)"
        }
    }
}

enum FlowRoutinePatcher {
    /// Matches the bridge's `routineSchema`, which will not carry a routine
    /// with more sections than this. A cap here is not about what a training
    /// block should look like; it is about not letting a patch push a routine
    /// out of the range the coach can still read back.
    static let maximumSections = 50

    /// Also from the bridge's `routineSchema`, for the same reason: a section
    /// pushed past this stops fitting in a snapshot, so the routine would drop
    /// out of the coach's view at the next sync.
    static let maximumExercisesPerSection = 100

    static func preview(json: String, routines: [Routine]) throws -> FlowRoutinePatchPreview {
        let cleaned = FlowRoutineExchange.sanitizedJSON(from: json)
        guard let data = cleaned.data(using: .utf8) else {
            throw FlowRoutinePatchError.invalidJSON("Patch text is not valid UTF-8.")
        }

        switch FlowRoutineExchange.detectPayload(in: cleaned) {
        case .routine:
            throw FlowRoutinePatchError.invalidJSON(
                "This looks like a full routine export, not a routine patch. Import it from the Routines screen instead."
            )
        case .coachContext:
            throw FlowRoutinePatchError.invalidJSON(
                "This is the coach context export, not a routine patch. Paste the patch the assistant produced."
            )
        case .coachPatch, .unknown:
            break
        }

        // Check the schema version before strict decoding so a stale-schema
        // patch fails with an actionable message instead of a missing-key
        // decode error.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let version = object["schemaVersion"] as? Int,
               !FlowRoutinePatch.supportedSchemaVersions.contains(version) {
                throw FlowRoutinePatchError.unsupportedSchema(version)
            }
            if object["baseContentHash"] == nil {
                throw FlowRoutinePatchError.missingField("baseContentHash")
            }
        }

        let patch: FlowRoutinePatch
        do {
            patch = try FlowRoutineExchange.decoder().decode(FlowRoutinePatch.self, from: data)
        } catch {
            throw FlowRoutinePatchError.invalidJSON(error.localizedDescription)
        }

        return try preview(patch: patch, routines: routines)
    }

    static func preview(patch: FlowRoutinePatch, routines: [Routine]) throws -> FlowRoutinePatchPreview {
        guard FlowRoutinePatch.supportedSchemaVersions.contains(patch.schemaVersion) else {
            throw FlowRoutinePatchError.unsupportedSchema(patch.schemaVersion)
        }
        guard !patch.operations.isEmpty else {
            throw FlowRoutinePatchError.noOperations
        }
        // Checked before anything is applied, so a patch that mixes a known
        // operation with one its declared version predates fails whole rather
        // than half-previewing.
        if let ahead = patch.operations.first(where: { $0.kind.minimumSchemaVersion > patch.schemaVersion }) {
            throw FlowRoutinePatchError.operationNeedsNewerSchema(
                kind: ahead.kind.rawValue,
                minimum: ahead.kind.minimumSchemaVersion,
                declared: patch.schemaVersion
            )
        }
        guard let routine = routines.first(where: { $0.id == patch.routineId }) else {
            throw FlowRoutinePatchError.routineNotFound(patch.routineId)
        }

        // A stale content hash is not an automatic rejection. Every operation
        // carries its expected before-value, so if all of them still match the
        // current content the patch rebases cleanly and previews; the caller
        // sees `rebasedFromHash` and can say so. If any operation no longer
        // matches, the patch is genuinely conflicted and the per-operation
        // failure is surfaced. With a current hash, an operation failure means
        // the patch itself is wrong and the error propagates untranslated.
        let actualHash = FlowRoutineRevision.contentHash(for: routine)
        let isRebasing = actualHash != patch.baseContentHash

        var updated = routine
        var diffs: [FlowRoutinePatchDiff] = []
        for (offset, operation) in patch.operations.enumerated() {
            do {
                let diff = try apply(operation, operationIndex: offset + 1, to: &updated)
                diffs.append(diff)
            } catch let error as FlowRoutinePatchError where isRebasing {
                throw FlowRoutinePatchError.staleConflict(
                    operationIndex: offset + 1,
                    reason: error.errorDescription ?? String(describing: error)
                )
            }
        }

        // "Would empty" means this patch did the emptying. A routine that
        // could not start a workout before the patch cannot be made worse by
        // one, and refusing there would reject perfectly sound edits to an
        // empty draft with an error describing something that did not happen:
        // a rename of an empty routine validates in the bridge and would fail
        // here, which is exactly the discover-by-rejection loop the coach
        // capability list exists to close.
        guard updated.canStartWorkout || !routine.canStartWorkout else {
            throw FlowRoutinePatchError.wouldEmptyRoutine
        }

        return FlowRoutinePatchPreview(
            patch: patch,
            originalRoutine: routine,
            updatedRoutine: updated,
            diffs: diffs,
            rebasedFromHash: isRebasing ? patch.baseContentHash : nil
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
                after: "\(exercise.name): \(value) reps",
                phaseConsequences: phaseConsequences(for: exercise, field: .reps, newBase: value)
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
                after: "\(exercise.name): \(value) sets",
                phaseConsequences: phaseConsequences(for: exercise, field: .sets, newBase: value)
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
                after: "\(exercise.name): \(value)s",
                phaseConsequences: phaseConsequences(for: exercise, field: .durationSeconds, newBase: value)
            )

        case .replaceRestBetweenSets:
            return try replaceRest(
                operation,
                operationIndex: operationIndex,
                fieldName: "restBetweenSetsSeconds",
                diffTitle: "Replace rest between sets",
                displayName: "rest between sets",
                current: { $0.restBetweenSetsSeconds },
                set: { $0.restBetweenSetsSeconds = $1 },
                in: &routine
            )

        case .replaceRestAfterExercise:
            return try replaceRest(
                operation,
                operationIndex: operationIndex,
                fieldName: "restAfterExerciseSeconds",
                diffTitle: "Replace rest after exercise",
                displayName: "rest after exercise",
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
            guard routine.sections[sectionIndex].exercises.count < Self.maximumExercisesPerSection else {
                throw FlowRoutinePatchError.tooManyExercisesInSection(
                    section: routine.sections[sectionIndex].name,
                    limit: Self.maximumExercisesPerSection
                )
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
            guard routine.sections[targetSectionIndex].exercises.count < Self.maximumExercisesPerSection else {
                throw FlowRoutinePatchError.tooManyExercisesInSection(
                    section: routine.sections[targetSectionIndex].name,
                    limit: Self.maximumExercisesPerSection
                )
            }
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

        case .addSection:
            guard let section = operation.section else {
                throw FlowRoutinePatchError.missingField("section")
            }
            let name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw FlowRoutinePatchError.invalidValue(field: "section.name", message: "must not be empty")
            }
            guard name.count <= 200 else {
                throw FlowRoutinePatchError.invalidValue(field: "section.name", message: "must be 200 characters or fewer")
            }
            guard !routine.sections.contains(where: { $0.id == section.id }) else {
                throw FlowRoutinePatchError.duplicateSectionId(section.id)
            }
            // The bridge cannot carry a routine with more sections than this
            // in a snapshot, so a routine allowed past the ceiling would drop
            // out of the coach's view entirely at the next sync.
            guard routine.sections.count < Self.maximumSections else {
                throw FlowRoutinePatchError.tooManySections(Self.maximumSections)
            }
            let insertIndex: Int
            if let afterSectionId = operation.afterSectionId {
                insertIndex = try sectionIndex(in: routine, id: afterSectionId) + 1
            } else {
                insertIndex = routine.sections.count
            }
            routine.sections.insert(Section(id: section.id, name: name, exercises: []), at: insertIndex)
            return FlowRoutinePatchDiff(
                operationIndex: operationIndex,
                title: "Add section",
                before: "[not present]",
                after: "\(name) (empty)"
            )

        case .renameRoutine:
            let value = try requireString(operation.newStringValue, "newStringValue")
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw FlowRoutinePatchError.invalidValue(field: "routine name", message: "must not be empty")
            }
            guard name.count <= 100 else {
                throw FlowRoutinePatchError.invalidValue(field: "routine name", message: "must be 100 characters or fewer")
            }
            // The routine name sits outside `contentHash`, which covers
            // sections only, so a stale-hash rebase can never notice a rename
            // that landed in between. `expectedStringValue` is the whole
            // concurrency guard here rather than a second opinion on one.
            try expectString(operation.expectedStringValue, actual: routine.name, field: "routine name")
            let before = routine.name
            routine.name = name
            return FlowRoutinePatchDiff(
                operationIndex: operationIndex,
                title: "Rename routine",
                before: before,
                after: name
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

    /// The three fields a `PhaseOverride` can diverge on. Rest has no override
    /// field, so `replaceRestBetweenSets` and `replaceRestAfterExercise` have
    /// nothing to fall out of step with.
    private enum PhaseField {
        case sets
        case reps
        case durationSeconds

        var unit: FlowRoutinePhaseConsequence.Unit {
            switch self {
            case .sets: return .sets
            case .reps: return .reps
            case .durationSeconds: return .seconds
            }
        }

        func value(in override: PhaseOverride) -> Int? {
            switch self {
            case .sets: return override.sets
            case .reps: return override.reps
            case .durationSeconds: return override.durationSeconds
            }
        }
    }

    /// The per-phase state a base-value change leaves behind.
    ///
    /// Silent unless at least one phase overrides the field being changed: an
    /// exercise with no override on that field previews exactly as it always
    /// has, with no extra rows and no empty section.
    private static func phaseConsequences(
        for exercise: ExerciseBlock,
        field: PhaseField,
        newBase: Int
    ) -> [FlowRoutinePhaseConsequence] {
        let phases = WorkoutPhase.allCases.filter { $0 != .base }
        let overridden = phases.compactMap { phase in
            exercise.phaseOverrides[phase].flatMap { field.value(in: $0) }
        }
        guard !overridden.isEmpty else { return [] }

        return phases.map { phase in
            guard let value = exercise.phaseOverrides[phase].flatMap({ field.value(in: $0) }) else {
                // Said out loud rather than left silent, so a phase missing
                // from the list is not read as a phase with no override.
                return FlowRoutinePhaseConsequence(
                    phase: phase,
                    unit: field.unit,
                    baseValue: newBase,
                    overrideValue: nil,
                    relation: .inheritsBase
                )
            }
            let relation: FlowRoutinePhaseConsequence.Relation
            if value == newBase {
                relation = .matchesBase
            } else if value < newBase {
                relation = .belowBase
            } else {
                relation = .stepsUpFromBase
            }
            return FlowRoutinePhaseConsequence(
                phase: phase,
                unit: field.unit,
                baseValue: newBase,
                overrideValue: value,
                relation: relation
            )
        }
    }

    private static func replaceRest(
        _ operation: FlowRoutinePatchOperation,
        operationIndex: Int,
        fieldName: String,
        diffTitle: String,
        displayName: String,
        current: (ExerciseBlock) -> Int,
        set: (inout ExerciseBlock, Int) -> Void,
        in routine: inout Routine
    ) throws -> FlowRoutinePatchDiff {
        let value = try requireInt(operation.newIntValue, "newIntValue")
        try validate(value, field: fieldName, range: 0...900)
        let location = try exerciseLocation(in: routine, id: try requireUUID(operation.exerciseId, "exerciseId"))
        var exercise = routine.sections[location.sectionIndex].exercises[location.exerciseIndex]
        let actual = current(exercise)
        try expectInt(operation.expectedIntValue, actual: actual, field: "\(exercise.name) \(displayName)")
        set(&exercise, value)
        routine.sections[location.sectionIndex].exercises[location.exerciseIndex] = exercise
        return FlowRoutinePatchDiff(
            operationIndex: operationIndex,
            title: diffTitle,
            before: "\(exercise.name): \(displayName) \(actual)s",
            after: "\(exercise.name): \(displayName) \(value)s"
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
