import Foundation
import SwiftData

enum AdjustmentDecision: String, Codable, CaseIterable {
    case none
    case proposed
    case applied
    case skipped

    var displayName: String {
        switch self {
        case .none: return "None"
        case .proposed: return "Proposed"
        case .applied: return "Applied"
        case .skipped: return "Skipped"
        }
    }
}

struct CompletedSetResult: Identifiable, Codable, Hashable {
    var id: UUID
    var exerciseId: UUID
    var exerciseName: String
    var setNumber: Int
    var side: WorkoutSide?
    var rating: SetRating
    var completedAt: Date

    init(_ result: SetResult) {
        id = result.id
        exerciseId = result.exerciseId
        exerciseName = result.exerciseName
        setNumber = result.setNumber
        side = result.side
        rating = result.rating
        completedAt = result.completedAt
    }
}

struct CompletedRoutineAdjustment: Identifiable, Codable, Hashable {
    var id: UUID
    var exerciseId: UUID
    var exerciseName: String
    var field: String
    var oldValue: Int
    var newValue: Int

    init(_ adjustment: RoutineAdjustment) {
        id = adjustment.id
        exerciseId = adjustment.exerciseId
        exerciseName = adjustment.exerciseName
        field = adjustment.field
        oldValue = adjustment.oldValue
        newValue = adjustment.newValue
    }
}

@Model
final class CompletedWorkout {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date
    var routineId: UUID
    var routineName: String
    var phaseRawValue: String
    var durationSeconds: Double
    var adjustmentDecisionRawValue: String
    var setResultsData: Data
    var proposedAdjustmentsData: Data
    var appliedAdjustmentsData: Data

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        routineId: UUID,
        routineName: String,
        phase: WorkoutPhase,
        durationSeconds: Double,
        setResults: [CompletedSetResult],
        proposedAdjustments: [CompletedRoutineAdjustment],
        appliedAdjustments: [CompletedRoutineAdjustment] = [],
        adjustmentDecision: AdjustmentDecision
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.routineId = routineId
        self.routineName = routineName
        self.phaseRawValue = phase.rawValue
        self.durationSeconds = durationSeconds
        self.adjustmentDecisionRawValue = adjustmentDecision.rawValue
        self.setResultsData = Self.encode(setResults)
        self.proposedAdjustmentsData = Self.encode(proposedAdjustments)
        self.appliedAdjustmentsData = Self.encode(appliedAdjustments)
    }
}

extension CompletedWorkout {
    var phase: WorkoutPhase {
        WorkoutPhase(rawValue: phaseRawValue) ?? .base
    }

    var adjustmentDecision: AdjustmentDecision {
        get { AdjustmentDecision(rawValue: adjustmentDecisionRawValue) ?? .none }
        set { adjustmentDecisionRawValue = newValue.rawValue }
    }

    var setResults: [CompletedSetResult] {
        get { Self.decode([CompletedSetResult].self, from: setResultsData) ?? [] }
        set { setResultsData = Self.encode(newValue) }
    }

    var proposedAdjustments: [CompletedRoutineAdjustment] {
        get { Self.decode([CompletedRoutineAdjustment].self, from: proposedAdjustmentsData) ?? [] }
        set { proposedAdjustmentsData = Self.encode(newValue) }
    }

    var appliedAdjustments: [CompletedRoutineAdjustment] {
        get { Self.decode([CompletedRoutineAdjustment].self, from: appliedAdjustmentsData) ?? [] }
        set { appliedAdjustmentsData = Self.encode(newValue) }
    }

    var formattedDuration: String {
        let elapsed = Int(durationSeconds.rounded())
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    func update(
        from session: WorkoutSession,
        decision: AdjustmentDecision,
        appliedAdjustments: [RoutineAdjustment]
    ) {
        startedAt = session.startedAt
        endedAt = session.endedAt ?? session.startedAt
        routineId = session.routine.id
        routineName = session.routine.name
        phaseRawValue = session.routine.currentPhase.rawValue
        durationSeconds = session.durationSeconds
        setResults = session.results.map(CompletedSetResult.init)
        proposedAdjustments = session.adjustments.map(CompletedRoutineAdjustment.init)
        self.appliedAdjustments = appliedAdjustments.map(CompletedRoutineAdjustment.init)
        adjustmentDecision = decision
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
