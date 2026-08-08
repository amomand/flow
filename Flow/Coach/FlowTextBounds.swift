import Foundation

/**
 The text ceilings the coach snapshot schema enforces, held in one place so
 the editors, the JSON import, and the patch path all measure against the
 same numbers.

 The bridge reads `bridge-worker/src/patch-operations.json` directly and
 Flow's values below point at its generated Swift view. That file owns the
 numbers; this type keeps the app-facing names and validation helpers.

 All bounds are UTF-16 code units, not Swift `count`, because UTF-16 is what
 the bridge's JavaScript measures without being asked. The two agree for most
 text and part company outside the Basic Multilingual Plane — most emoji —
 and wherever a character is written as a base plus combining marks.
 */
enum FlowTextBounds {
    /// Routine, section and exercise names as the snapshot carries them.
    static let name = FlowPatchContract.name
    /// A routine name a coach proposes (createRoutine, renameRoutine).
    /// Deliberately tighter than `name`.
    static let proposedRoutineName = FlowPatchContract.proposedRoutineName
    /// Per-exercise notes.
    static let exerciseNotes = FlowPatchContract.exerciseNotes
    /// The free-text constraints notes attached to a coach context export.
    static let constraintsNotes = FlowPatchContract.constraintsNotes

    /**
     What counts as padding around a name.

     U+FEFF joins `whitespacesAndNewlines` to make this set a strict superset
     of what JavaScript's `trim` strips. That superset is what makes the two
     sides agree rather than merely trim similarly: a name trimmed with this
     set has nothing left at either end for the bridge to strip, so the length
     the app measured is the length the bridge measures, and non-empty here
     implies non-blank there.
     */
    static let namePadding = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

    static func trimmedName(_ value: String) -> String {
        value.trimmingCharacters(in: namePadding)
    }

    /// The length the bridge will measure for this value.
    static func measuredLength(_ value: String) -> Int {
        value.utf16.count
    }

    static func fitsName(_ value: String) -> Bool {
        measuredLength(trimmedName(value)) <= name
    }

    /// Non-empty once trimmed, which is what both `canSave` gates and the
    /// bridge's blankness check mean by "has a name".
    static func isPresentName(_ value: String) -> Bool {
        !trimmedName(value).isEmpty
    }

    /// An over-bound field described for the person typing in it, or nil
    /// while the value fits. The count is the one the bridge will measure,
    /// which is why it can disagree with what the person sees for emoji and
    /// combining marks.
    static func overflowMessage(_ value: String, limit: Int, label: String) -> String? {
        let length = measuredLength(trimmedName(value))
        guard length > limit else { return nil }
        return "\(label) is \(length)/\(limit) characters"
    }

    /**
     The numeric ceilings the snapshot schema enforces, matching the bridge's
     `exerciseSchema` and the patch path's own range checks. Kept beside the
     text bounds because `firstBoundsProblem` is the one gate the editors and
     the JSON import share, and a `sets` of 12 fails the envelope exactly the
     way a 201-character name does.
     */
    static let setsRange = FlowPatchContract.setsRange
    static let repsRange = FlowPatchContract.repsRange
    static let durationSecondsRange = FlowPatchContract.durationSecondsRange
    static let restSecondsRange = FlowPatchContract.restSecondsRange

    /**
     The first field in the routine the snapshot schema would refuse,
     described for the person editing it, or nil when everything fits.

     One message rather than a list because the envelope fails whole either
     way; the point is to hold the save until nothing in the routine can cost
     the coach every routine at sync time, and to say which field is the
     problem while the person is still looking at it.
     */
    static func firstBoundsProblem(in routine: Routine) -> String? {
        if !isPresentName(routine.name) { return "routine needs a name" }
        if let over = overflowMessage(routine.name, limit: name, label: "routine name") { return over }
        if routine.sections.count > FlowRoutinePatcher.maximumSections {
            return "routine has \(routine.sections.count) sections; a snapshot carries at most \(FlowRoutinePatcher.maximumSections)"
        }
        for section in routine.sections {
            if !isPresentName(section.name) { return "a section needs a name" }
            if let over = overflowMessage(section.name, limit: name, label: "section \"\(shortened(section.name))\" name") {
                return over
            }
            if section.exercises.count > FlowRoutinePatcher.maximumExercisesPerSection {
                return "section \"\(shortened(section.name))\" has \(section.exercises.count) exercises; a snapshot carries at most \(FlowRoutinePatcher.maximumExercisesPerSection)"
            }
            for exercise in section.exercises {
                if !isPresentName(exercise.name) { return "an exercise in \"\(shortened(section.name))\" needs a name" }
                if let over = overflowMessage(exercise.name, limit: name, label: "exercise \"\(shortened(exercise.name))\" name") {
                    return over
                }
                if measuredLength(exercise.notes) > exerciseNotes {
                    return "\"\(shortened(exercise.name))\" notes are \(measuredLength(exercise.notes))/\(exerciseNotes) characters"
                }
                if let out = outOfRange(exercise.sets, setsRange, "\"\(shortened(exercise.name))\" sets") { return out }
                if let out = outOfRange(exercise.reps, repsRange, "\"\(shortened(exercise.name))\" reps") { return out }
                if let duration = exercise.durationSeconds,
                   let out = outOfRange(duration, durationSecondsRange, "\"\(shortened(exercise.name))\" time") { return out }
                if let out = outOfRange(exercise.restBetweenSetsSeconds, restSecondsRange, "\"\(shortened(exercise.name))\" rest between sets") { return out }
                if let out = outOfRange(exercise.restAfterExerciseSeconds, restSecondsRange, "\"\(shortened(exercise.name))\" rest after exercise") { return out }
                for (phase, override) in exercise.phaseOverrides {
                    let label = "\"\(shortened(exercise.name))\" \(phase.rawValue) override"
                    if let sets = override.sets, let out = outOfRange(sets, setsRange, "\(label) sets") { return out }
                    if let reps = override.reps, let out = outOfRange(reps, repsRange, "\(label) reps") { return out }
                    if let duration = override.durationSeconds,
                       let out = outOfRange(duration, durationSecondsRange, "\(label) time") { return out }
                }
            }
        }
        return nil
    }

    private static func outOfRange(_ value: Int, _ range: ClosedRange<Int>, _ label: String) -> String? {
        guard !range.contains(value) else { return nil }
        return "\(label) must be between \(range.lowerBound) and \(range.upperBound)"
    }

    /// The routine with every name trimmed the way the patch path trims, so
    /// what the editors save is what the snapshot will carry byte for byte.
    static func withTrimmedNames(_ routine: Routine) -> Routine {
        var trimmed = routine
        trimmed.name = trimmedName(routine.name)
        for si in trimmed.sections.indices {
            trimmed.sections[si].name = trimmedName(trimmed.sections[si].name)
            for ei in trimmed.sections[si].exercises.indices {
                trimmed.sections[si].exercises[ei].name = trimmedName(trimmed.sections[si].exercises[ei].name)
            }
        }
        return trimmed
    }

    /**
     Whether the constraints notes as typed would be refused at upload,
     described for the person typing them, or nil while they fit.

     Measured on what `FlowCoachConstraints` will actually store — its own
     trim, not `namePadding` — because the bound belongs to the uploaded
     value. This is the one bounded field with no other editor validation and
     the largest ceiling, so a pasted paragraph is the likeliest way anyone
     hits any of these bounds.
     */
    static func constraintsNotesProblem(_ raw: String) -> String? {
        guard let stored = FlowCoachConstraints(notes: raw).notes else { return nil }
        let length = measuredLength(stored)
        guard length > constraintsNotes else { return nil }
        return "notes are \(length)/\(constraintsNotes) characters"
    }

    /// A name shortened for use inside an error message, so a 200-character
    /// name does not swallow the sentence pointing at it.
    private static func shortened(_ value: String) -> String {
        let trimmed = trimmedName(value)
        guard trimmed.count > 20 else { return trimmed }
        return "\(trimmed.prefix(20))…"
    }
}
