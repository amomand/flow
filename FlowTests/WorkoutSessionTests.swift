import XCTest
@testable import Flow

final class WorkoutSessionTests: XCTestCase {
    func testDuplicateExerciseNamesApplyAdjustmentById() {
        let firstId = UUID()
        let secondId = UUID()
        let routine = Routine(
            name: "Duplicate Names",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(id: firstId, name: "Row", sets: 3, reps: 8),
                    ExerciseBlock(id: secondId, name: "Row", sets: 3, reps: 12)
                ])
            ]
        )
        let session = WorkoutSession(routine: routine)
        session.results = (1...3).map {
            SetResult(exerciseId: firstId, exerciseName: "Row", setNumber: $0, side: nil, rating: .tooEasy)
        }
        session.adjustments = session.computeAdjustments()

        var updated = routine
        session.applyAdjustments(to: &updated)

        XCTAssertEqual(updated.sections[0].exercises[0].reps, 10)
        XCTAssertEqual(updated.sections[0].exercises[1].reps, 12)
    }

    func testNonBasePhaseDoesNotMutateBaseProgression() {
        let exerciseId = UUID()
        let routine = Routine(
            name: "Deload",
            sections: [
                Section(name: "Main", exercises: [
                    ExerciseBlock(
                        id: exerciseId,
                        name: "Push-up",
                        sets: 3,
                        reps: 10,
                        phaseOverrides: [.deload: PhaseOverride(sets: 2, reps: 8)]
                    )
                ])
            ],
            currentPhase: .deload
        )
        let session = WorkoutSession(routine: routine)
        session.results = (1...2).map {
            SetResult(exerciseId: exerciseId, exerciseName: "Push-up", setNumber: $0, side: nil, rating: .tooEasy)
        }

        XCTAssertTrue(session.computeAdjustments().isEmpty)

        var updated = routine
        session.adjustments = session.computeAdjustments()
        session.applyAdjustments(to: &updated)
        XCTAssertEqual(updated.sections[0].exercises[0].reps, 10)
    }

    func testFinishingCapturesStableEndTimeAndDuration() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let endedAt = startedAt.addingTimeInterval(75)
        let routine = Routine(
            name: "Quick",
            sections: [Section(name: "Main", exercises: [ExerciseBlock(name: "Squat", sets: 1, reps: 5)])]
        )
        let session = WorkoutSession(routine: routine, startedAt: startedAt)

        session.completeCurrentSet(completedAt: endedAt)

        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.endedAt, endedAt)
        XCTAssertEqual(session.formattedDuration, "1:15")
    }

    func testEmptyRoutineStartsFinished() {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let session = WorkoutSession(routine: Routine(name: "Empty"), startedAt: startedAt)

        XCTAssertTrue(session.steps.isEmpty)
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.endedAt, startedAt)
    }

    func testTimedPerSideExercisesCreateSideSteps() {
        let routine = Routine(
            name: "Sides",
            sections: [
                Section(name: "Core", exercises: [
                    ExerciseBlock(name: "Side plank", sets: 2, reps: 30, durationSeconds: 30, perSide: true)
                ])
            ]
        )

        let steps = routine.buildSteps()

        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps.map(\.side), [.left, .right, .left, .right])
        XCTAssertEqual(steps.map(\.setNumber), [1, 1, 2, 2])
    }

    func testTimedToggleClearsStaleHiddenPhaseOverrides() {
        var exercise = ExerciseBlock(
            name: "Hold",
            sets: 2,
            reps: 30,
            durationSeconds: 30,
            phaseOverrides: [
                .peak: PhaseOverride(sets: 2, reps: 45, durationSeconds: 45),
                .deload: PhaseOverride(durationSeconds: 20)
            ]
        )

        exercise.setTimed(false)

        XCTAssertNil(exercise.durationSeconds)
        XCTAssertNil(exercise.phaseOverrides[.peak]?.durationSeconds)
        XCTAssertNil(exercise.phaseOverrides[.deload])

        exercise.phaseOverrides[.peak] = PhaseOverride(reps: 12)
        exercise.setTimed(true)
        XCTAssertNil(exercise.phaseOverrides[.peak])
    }
}
