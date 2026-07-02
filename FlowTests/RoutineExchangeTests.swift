import XCTest
@testable import Flow

final class RoutineExchangeTests: XCTestCase {
    // MARK: - Revision hashes

    func testContentHashIgnoresCurrentPhase() {
        var routine = makeRoutine()
        let baseHash = FlowRoutineRevision.contentHash(for: routine)

        routine.currentPhase = .peak

        XCTAssertEqual(FlowRoutineRevision.contentHash(for: routine), baseHash)
    }

    func testContentHashChangesWhenStructureChanges() {
        var routine = makeRoutine()
        let baseHash = FlowRoutineRevision.contentHash(for: routine)

        routine.sections[0].exercises[0].reps = 12

        XCTAssertNotEqual(FlowRoutineRevision.contentHash(for: routine), baseHash)
    }

    func testContentHashIsStableAcrossRepeatedHashing() {
        let routine = makeRoutine()

        XCTAssertEqual(
            FlowRoutineRevision.contentHash(for: routine),
            FlowRoutineRevision.contentHash(for: routine)
        )
    }

    func testStateHashTracksCurrentPhaseOnly() {
        var routine = makeRoutine()
        let baseHash = FlowRoutineRevision.stateHash(for: routine)

        routine.sections[0].exercises[0].reps = 12
        XCTAssertEqual(FlowRoutineRevision.stateHash(for: routine), baseHash)

        routine.currentPhase = .deload
        XCTAssertNotEqual(FlowRoutineRevision.stateHash(for: routine), baseHash)
    }

    func testHashSchemesArePrefixedAndDistinct() {
        let routine = makeRoutine()

        XCTAssertTrue(FlowRoutineRevision.contentHash(for: routine).hasPrefix("c1-"))
        XCTAssertTrue(FlowRoutineRevision.stateHash(for: routine).hasPrefix("s1-"))
    }

    // MARK: - Payload detection

    func testDetectsWholeRoutinePayload() throws {
        let json = try encodeToJSON(makeRoutine())
        XCTAssertEqual(FlowRoutineExchange.detectPayload(in: json), .routine)
    }

    func testDetectsCoachPatchPayload() throws {
        let routine = makeRoutine()
        let patch = FlowRoutinePatch(
            schemaVersion: 2,
            routineId: routine.id,
            baseContentHash: FlowRoutineRevision.contentHash(for: routine),
            exportedAt: nil,
            rationale: "Detect me.",
            operations: [
                FlowRoutinePatchOperation(
                    kind: .replaceExerciseReps,
                    exerciseId: routine.sections[0].exercises[0].id,
                    expectedIntValue: 8,
                    newIntValue: 10
                )
            ]
        )
        let json = try encodeToJSON(patch)
        XCTAssertEqual(FlowRoutineExchange.detectPayload(in: json), .coachPatch)
    }

    func testDetectsCoachContextPayload() throws {
        let context = FlowCoachContext.make(routines: [makeRoutine()], strengthWorkouts: [], cardioWorkouts: [])
        let json = try XCTUnwrap(context.jsonString())
        XCTAssertEqual(FlowRoutineExchange.detectPayload(in: json), .coachContext)
    }

    func testDetectsUnknownPayload() {
        XCTAssertEqual(FlowRoutineExchange.detectPayload(in: "{\"hello\": 1}"), .unknown)
        XCTAssertEqual(FlowRoutineExchange.detectPayload(in: "not json at all"), .unknown)
    }

    // MARK: - Sanitised JSON extraction

    func testSanitizedJSONStripsCodeFences() {
        let fenced = "```json\n{\"schemaVersion\":2}\n```"
        XCTAssertEqual(FlowRoutineExchange.sanitizedJSON(from: fenced), "{\"schemaVersion\":2}")
    }

    func testSanitizedJSONStripsSurroundingProse() {
        let chatty = "Sure! Here is the patch you asked for:\n{\"schemaVersion\":2}\nLet me know if you want changes."
        XCTAssertEqual(FlowRoutineExchange.sanitizedJSON(from: chatty), "{\"schemaVersion\":2}")
    }

    func testSanitizedJSONLeavesCleanJSONUnchanged() {
        let clean = "{\"schemaVersion\":2}"
        XCTAssertEqual(FlowRoutineExchange.sanitizedJSON(from: clean), clean)
        XCTAssertEqual(FlowRoutineExchange.sanitizedJSON(from: "  \(clean)\n"), clean)
    }

    func testSanitizedJSONWithoutBracesIsTrimmedFallback() {
        XCTAssertEqual(FlowRoutineExchange.sanitizedJSON(from: "  no json here \n"), "no json here")
    }

    // MARK: - Helpers

    private func makeRoutine() -> Routine {
        Routine(
            name: "Exchange",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(name: "Press", sets: 3, reps: 8)
                ])
            ],
            currentPhase: .base
        )
    }

    private func encodeToJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try FlowRoutineExchange.encoder().encode(value)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
