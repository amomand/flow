import XCTest
@testable import Flow

final class WorkoutSessionTests: XCTestCase {
    func testFinishedWorkoutCapturesStableDuration() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let routine = Routine(
            name: "Duration Test",
            sections: [
                Section(
                    name: "Main",
                    exercises: [
                        ExerciseBlock(
                            name: "Push-up",
                            sets: 1,
                            reps: 10,
                            restBetweenSetsSeconds: 0,
                            restAfterExerciseSeconds: 0
                        )
                    ]
                )
            ]
        )
        let session = WorkoutSession(routine: routine, startedAt: startedAt)

        session.completeCurrentSet(completedAt: startedAt.addingTimeInterval(90))
        let firstDuration = session.durationSeconds

        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.endedAt, startedAt.addingTimeInterval(90))
        XCTAssertEqual(firstDuration, 90, accuracy: 0.001)

        _ = session.refreshAgainstClock(now: startedAt.addingTimeInterval(240))

        XCTAssertEqual(session.durationSeconds, firstDuration, accuracy: 0.001)
        XCTAssertTrue(session.generateSummaryMarkdown().contains("**Duration:** 1:30"))
    }
}
