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

    /// What a patch is aimed at.
    ///
    /// A routine that does not exist yet has no id to anchor to and no content
    /// to hash, so the two branches genuinely need different required fields.
    /// Modelling that as a discriminator keeps both branches strict, rather
    /// than making the anchor optional for everyone and hoping.
    enum Target: String, Codable, Equatable {
        case existingRoutine
        case newRoutine
    }

    let schemaVersion: Int
    /// Absent in schema 2, where every patch edited a routine that existed.
    let target: Target
    /// Both nil exactly when `target` is `.newRoutine`.
    let routineId: UUID?
    let baseContentHash: String?
    let exportedAt: Date?
    let rationale: String
    let operations: [FlowRoutinePatchOperation]

    init(
        schemaVersion: Int,
        target: Target = .existingRoutine,
        routineId: UUID? = nil,
        baseContentHash: String? = nil,
        exportedAt: Date? = nil,
        rationale: String,
        operations: [FlowRoutinePatchOperation]
    ) {
        self.schemaVersion = schemaVersion
        self.target = target
        self.routineId = routineId
        self.baseContentHash = baseContentHash
        self.exportedAt = exportedAt
        self.rationale = rationale
        self.operations = operations
    }

    /// Schema 2 patches carry no `target`, and there was only one thing a
    /// patch could be aimed at, so their absence is not ambiguous.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        target = try container.decodeIfPresent(Target.self, forKey: .target) ?? .existingRoutine
        routineId = try container.decodeIfPresent(UUID.self, forKey: .routineId)
        baseContentHash = try container.decodeIfPresent(String.self, forKey: .baseContentHash)
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt)
        rationale = try container.decode(String.self, forKey: .rationale)
        operations = try container.decode([FlowRoutinePatchOperation].self, forKey: .operations)
    }
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
    /// A whole routine, only for `createRoutine`. It reuses `Routine` because
    /// a created routine is exactly a routine; there is no partial shape to
    /// model and nothing to leave out.
    var routine: Routine? = nil

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
        case createRoutine

        /// The first schema version this operation belongs to. A patch may
        /// only use operations its declared version knows about, so a coach
        /// that was told "this build speaks schema 2" cannot smuggle a newer
        /// operation through under the older version number.
        var minimumSchemaVersion: Int {
            switch self {
            case .renameRoutine, .addSection, .createRoutine:
                return 3
            default:
                return 2
            }
        }
    }
}

struct FlowRoutinePatchPreview {
    let patch: FlowRoutinePatch
    /// Nil for a create, which has nothing to have been before.
    let originalRoutine: Routine?
    let updatedRoutine: Routine
    let diffs: [FlowRoutinePatchDiff]

    var isCreate: Bool { originalRoutine == nil }
    /// The patch's stale `baseContentHash` when the routine changed after the
    /// patch was written but every operation's expected before-value still
    /// matched, so Flow rebased it onto the current content. `nil` when the
    /// patch previewed against the exact content it was written for.
    var rebasedFromHash: String? = nil
}

struct FlowRoutinePatchDiff: Identifiable, Equatable, Codable {
    let operationIndex: Int
    /// Position within one operation's rows. A create is a single operation
    /// that produces a row per section and per exercise, and two identical
    /// exercises would otherwise share an id and confuse the list they are
    /// rendered into. Zero for every operation that produces one row.
    var sequence: Int = 0
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
        "\(operationIndex)-\(sequence)-\(title)-\(before)-\(after)"
    }

    enum CodingKeys: String, CodingKey {
        case operationIndex, sequence, title, before, after, phaseConsequences
    }
}

extension FlowRoutinePatchDiff {
    /// History records written before phase consequences existed have no such
    /// key, and must keep decoding.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationIndex = try container.decode(Int.self, forKey: .operationIndex)
        sequence = try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
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
    /// An id the created routine borrowed from a routine that already exists.
    /// Distinct from the within-routine case: the remedy is a fresh id, not
    /// removing a repeat.
    case exerciseIdUsedByAnotherRoutine(id: UUID, routineName: String)
    case beforeValueMismatch(field: String, expected: String, actual: String)
    case invalidValue(field: String, message: String)
    case noOperations
    case wouldEmptyRoutine
    case duplicateSectionId(UUID)
    case tooManySections(Int)
    case tooManyRoutines(Int)
    case tooManyExercisesInSection(section: String, limit: Int)
    /// A create whose routine is already here. Usually a retry of something
    /// that landed, so it is reported as superseded rather than broken.
    case routineAlreadyExists(UUID)
    /// A create whose id is here but whose content is not the content that
    /// landed. A revision that reused its own earlier id, not a retry.
    case routineIdReused(name: String)
    case createMustStandAlone
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
        case .exerciseIdUsedByAnotherRoutine(_, let routineName):
            return "This draft reuses an exercise id that already belongs to \(routineName). Ask the coach for a fresh draft with new exercise ids."
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
        case .tooManyRoutines(let limit):
            return "You already have \(limit) routines, which is as many as the coach can be sent. Remove one before adding another."
        case .tooManyExercisesInSection(let section, let limit):
            return "Routine patch would take \(section) past \(limit) exercises."
        case .routineAlreadyExists:
            return "This routine is already here, so this draft has already been applied."
        case .routineIdReused(let name):
            return "\(name) already uses this draft's routine id, but it is not the same routine. If this draft is the one you want, ask the coach for a fresh one with a new routine id."
        case .createMustStandAlone:
            return "A patch that creates a routine must contain that one operation and nothing else."
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

    /// A snapshot carries at most this many routines. `createRoutine` is the
    /// first operation that can grow the count, and going past it is worse
    /// than the other ceilings: the next snapshot upload fails whole, so the
    /// coach stops seeing anything at all rather than losing one routine.
    static let maximumRoutines = 50

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
            // A create has no routine to anchor to, so the anchor is only
            // required on the branch that edits one.
            if object["target"] as? String != FlowRoutinePatch.Target.newRoutine.rawValue,
               object["baseContentHash"] == nil {
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
        if patch.target == .newRoutine {
            return try previewCreate(patch: patch, routines: routines)
        }

        guard let routineId = patch.routineId else {
            throw FlowRoutinePatchError.missingField("routineId")
        }
        guard patch.baseContentHash != nil else {
            throw FlowRoutinePatchError.missingField("baseContentHash")
        }
        // A create arriving without its discriminator would otherwise be read
        // as an edit to a routine that happens not to exist, and reported as a
        // missing routine rather than as the malformed patch it is.
        if patch.operations.contains(where: { $0.kind == .createRoutine }) {
            throw FlowRoutinePatchError.invalidValue(
                field: "target",
                message: "createRoutine belongs to a patch with target newRoutine"
            )
        }
        guard let routine = routines.first(where: { $0.id == routineId }) else {
            throw FlowRoutinePatchError.routineNotFound(routineId)
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

    /// A new routine arrives whole.
    ///
    /// Deliberately not a create followed by a stream of `addExercise`
    /// operations: the preview would then have to render intermediate states
    /// of a routine that never existed in any of them, and the person
    /// approving it would be reading a history rather than a routine.
    private static func previewCreate(
        patch: FlowRoutinePatch,
        routines: [Routine]
    ) throws -> FlowRoutinePatchPreview {
        guard patch.routineId == nil, patch.baseContentHash == nil else {
            throw FlowRoutinePatchError.invalidValue(
                field: "target",
                message: "a newRoutine patch anchors to nothing, so it carries no routineId or baseContentHash"
            )
        }
        guard patch.operations.count == 1, let operation = patch.operations.first,
              operation.kind == .createRoutine else {
            throw FlowRoutinePatchError.createMustStandAlone
        }
        guard let routine = operation.routine else {
            throw FlowRoutinePatchError.missingField("routine")
        }

        let name = routine.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw FlowRoutinePatchError.invalidValue(field: "routine.name", message: "must not be empty")
        }
        try check(name, atMost: 100, field: "routine.name")
        guard !routine.sections.isEmpty else {
            throw FlowRoutinePatchError.invalidValue(field: "routine.sections", message: "must contain at least one section")
        }
        guard routine.sections.count <= maximumSections else {
            throw FlowRoutinePatchError.tooManySections(maximumSections)
        }

        var sectionIds: Set<UUID> = []
        var exerciseIds: Set<UUID> = []
        var created = routine
        created.name = name

        for index in created.sections.indices {
            // The field name reaches the person reading the error, and a
            // create can carry many sections, so it has to say which one.
            let field = "routine.sections[\(index)].name"
            let sectionName = created.sections[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sectionName.isEmpty else {
                throw FlowRoutinePatchError.invalidValue(field: field, message: "must not be empty")
            }
            try check(sectionName, atMost: 200, field: field)
            created.sections[index].name = sectionName

            guard sectionIds.insert(created.sections[index].id).inserted else {
                throw FlowRoutinePatchError.duplicateSectionId(created.sections[index].id)
            }
            guard created.sections[index].exercises.count <= maximumExercisesPerSection else {
                throw FlowRoutinePatchError.tooManyExercisesInSection(
                    section: sectionName,
                    limit: maximumExercisesPerSection
                )
            }
            for exerciseIndex in created.sections[index].exercises.indices {
                var exercise = created.sections[index].exercises[exerciseIndex]
                exercise.phaseOverrides = exercise.phaseOverrides.filter { !$0.value.isEmpty }
                exercise = try validatedExercise(exercise)
                guard exerciseIds.insert(exercise.id).inserted else {
                    throw FlowRoutinePatchError.duplicateExerciseId(exercise.id)
                }
                created.sections[index].exercises[exerciseIndex] = exercise
            }
        }

        guard created.canStartWorkout else {
            throw FlowRoutinePatchError.wouldEmptyRoutine
        }

        // Checked against the normalised routine, not the raw draft. What an
        // earlier apply stored was `created`, with names trimmed and empty
        // phase overrides dropped, so hashing the draft as it arrived would
        // make a byte-identical retry of a landed draft look like a revision.
        //
        // "Already applied" has to mean the same routine, not merely the same
        // id: a coach revising its own earlier draft will happily reuse the id
        // it generated, and treating that as a completed retry would swallow
        // the revision behind a reassuring chip. Compared on sections and
        // name, not phase, which is state the user owns once the routine is
        // theirs; a toggled phase does not make a retry into a revision.
        if let existing = routines.first(where: { $0.id == created.id }) {
            let sameContent = FlowRoutineRevision.contentHash(for: existing)
                == FlowRoutineRevision.contentHash(for: created)
            guard sameContent, existing.name == created.name else {
                throw FlowRoutinePatchError.routineIdReused(name: existing.name)
            }
            throw FlowRoutinePatchError.routineAlreadyExists(created.id)
        }

        guard routines.count < maximumRoutines else {
            throw FlowRoutinePatchError.tooManyRoutines(maximumRoutines)
        }

        // Exercise ids are checked against every other routine, not just this
        // one. Nothing in the store enforces it, but whole-routine import has
        // always reassigned ids on the way in, so globally fresh ids are what
        // the rest of the app already assumes, and history reads more simply
        // when an id means one exercise. After the collision check, so a retry
        // is not reported as borrowing its own exercise ids.
        var ownerByExerciseId: [UUID: String] = [:]
        for existing in routines {
            for exercise in existing.sections.flatMap(\.exercises) {
                ownerByExerciseId[exercise.id] = existing.name
            }
        }
        if let borrowed = created.sections.flatMap({ $0.exercises }).first(where: { ownerByExerciseId[$0.id] != nil }) {
            throw FlowRoutinePatchError.exerciseIdUsedByAnotherRoutine(
                id: borrowed.id,
                routineName: ownerByExerciseId[borrowed.id] ?? "another routine"
            )
        }

        var diffs = [FlowRoutinePatchDiff(
            operationIndex: 1,
            sequence: 0,
            title: "Create routine",
            before: "[not present]",
            after: "\(created.name) — starts in \(created.currentPhase.displayName)"
        )]
        for section in created.sections {
            diffs.append(FlowRoutinePatchDiff(
                operationIndex: 1,
                sequence: diffs.count,
                title: "Add section",
                before: "[not present]",
                after: section.name
            ))
            for exercise in section.exercises {
                diffs.append(FlowRoutinePatchDiff(
                    operationIndex: 1,
                    sequence: diffs.count,
                    title: "Add exercise",
                    before: "[not present]",
                    after: "\(section.name): \(summary(of: exercise))"
                ))
            }
        }

        return FlowRoutinePatchPreview(
            patch: patch,
            originalRoutine: nil,
            updatedRoutine: created,
            diffs: diffs
        )
    }

    private static func summary(of exercise: ExerciseBlock) -> String {
        if let duration = exercise.durationSeconds {
            return "\(exercise.name) \(exercise.sets)x\(duration)s"
        }
        return "\(exercise.name) \(exercise.sets)x\(exercise.reps)"
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
            try check(value, atMost: 500, field: "notes")
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
            exercise = try validatedExercise(exercise)
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

        case .createRoutine:
            // Unreachable: `previewCreate` owns this operation, and the
            // existing-routine branch refuses a patch containing one. Stated
            // rather than left to a default, so adding an operation kind still
            // fails to compile until it is handled here.
            throw FlowRoutinePatchError.createMustStandAlone

        case .addSection:
            guard let section = operation.section else {
                throw FlowRoutinePatchError.missingField("section")
            }
            let name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw FlowRoutinePatchError.invalidValue(field: "section.name", message: "must not be empty")
            }
            try check(name, atMost: 200, field: "section.name")
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
            try check(name, atMost: 100, field: "routine name")
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

    /**
     Bound a string the way the bridge bounds it: in UTF-16 code units.

     Swift's `count` is grapheme clusters and the bridge's `length` is UTF-16
     code units. They agree for most text and part company wherever one
     character spans more than one code unit: anything outside the Basic
     Multilingual Plane, which is most emoji, and anything written as a base
     character plus combining marks, which covers accents typed as a sequence,
     joined emoji, and scripts that hang dependent signs off a base letter.
     Everyday Cyrillic, Greek, Arabic, Hebrew and CJK sit in the BMP at one
     code unit per letter and count the same either way.

     So a name of 100 emoji was 100 to the app and 200 to the bridge. The
     bridge was the stricter side everywhere, which meant a name the app
     accepted was one the coach could not propose, and the rejection made no
     sense to the person who typed it.

     UTF-16 is the contract because it is what the bridge's JavaScript measures
     without being asked. Teaching JavaScript about grapheme clusters is the
     more correct direction and far more work for a difference nobody hits
     deliberately.

     Every bounded string on the patch path goes through here so the unit is
     stated once rather than rediscovered per field.
     */
    private static func check(_ value: String, atMost limit: Int, field: String) throws {
        guard value.utf16.count <= limit else {
            throw FlowRoutinePatchError.invalidValue(field: field, message: "must be \(limit) characters or fewer")
        }
    }

    /**
     Check an exercise and hand back the version that may be stored.

     Returns rather than validating in place because the name has to be stored
     as it was measured. Bounding the trimmed name and then storing the
     untrimmed one leaves the app holding a name longer than the bound it just
     enforced, and the two sides do not trim the same characters: Swift's
     `whitespacesAndNewlines` takes U+0085 where JavaScript's `trim` does not.
     A name of 200 letters and a trailing U+0085 passed here at 200 and was
     stored at 201, and the next snapshot upload then failed whole, taking
     every routine out of the coach's view rather than failing anywhere the
     person could see.

     Routine and section names have always been written back this way; this is
     the exercise name catching up, and it is what the retry check above
     already assumes when it calls the stored routine "names trimmed".
     */
    private static func validatedExercise(_ exercise: ExerciseBlock) throws -> ExerciseBlock {
        var stored = exercise
        let name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw FlowRoutinePatchError.invalidValue(field: "exercise.name", message: "must not be empty")
        }
        // The bridge caps this at 200 and the app did not, so a patch could
        // store a name the next snapshot upload would refuse, taking the whole
        // routine out of the coach's view. Bounded on the trimmed name, which
        // is what the bridge measures.
        try check(name, atMost: 200, field: "exercise.name")
        stored.name = name
        try validate(exercise.sets, field: "exercise.sets", range: 1...10)
        try validate(exercise.reps, field: "exercise.reps", range: 1...100)
        if let duration = exercise.durationSeconds {
            try validate(duration, field: "exercise.durationSeconds", range: 1...3600)
        }
        try validate(exercise.restBetweenSetsSeconds, field: "exercise.restBetweenSetsSeconds", range: 0...900)
        try validate(exercise.restAfterExerciseSeconds, field: "exercise.restAfterExerciseSeconds", range: 0...900)
        try check(exercise.notes, atMost: 500, field: "exercise.notes")
        for override in exercise.phaseOverrides.values {
            try validatePhaseOverride(override)
        }
        return stored
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
