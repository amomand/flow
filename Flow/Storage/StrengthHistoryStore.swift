import Foundation
import SwiftData

@MainActor
@Observable
final class StrengthHistoryStore {
    enum StorageState: Equatable {
        case persistent
        case inMemoryFallback(String)
    }

    private let container: ModelContainer
    private(set) var storageState: StorageState
    private(set) var workouts: [CompletedWorkout] = []

    init() {
        let result = Self.makeContainer()
        container = result.container
        storageState = result.state
        reload()
    }

    func reload() {
        let descriptor = FetchDescriptor<CompletedWorkout>(
            sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
        )
        workouts = (try? container.mainContext.fetch(descriptor)) ?? []
    }

    @discardableResult
    func record(
        session: WorkoutSession,
        decision: AdjustmentDecision,
        appliedAdjustments: [RoutineAdjustment] = []
    ) -> CompletedWorkout {
        let context = container.mainContext
        let id = session.id
        var descriptor = FetchDescriptor<CompletedWorkout>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        let workout: CompletedWorkout
        if let existing = try? context.fetch(descriptor).first {
            existing.update(from: session, decision: decision, appliedAdjustments: appliedAdjustments)
            workout = existing
        } else {
            let newWorkout = CompletedWorkout(
                id: session.id,
                startedAt: session.startedAt,
                endedAt: session.endedAt ?? session.startedAt,
                routineId: session.routine.id,
                routineName: session.routine.name,
                phase: session.routine.currentPhase,
                durationSeconds: session.durationSeconds,
                setResults: session.results.map(CompletedSetResult.init),
                proposedAdjustments: session.adjustments.map(CompletedRoutineAdjustment.init),
                appliedAdjustments: appliedAdjustments.map(CompletedRoutineAdjustment.init),
                adjustmentDecision: decision
            )
            context.insert(newWorkout)
            workout = newWorkout
        }

        try? context.save()
        reload()
        return workout
    }

    private static func makeContainer() -> (container: ModelContainer, state: StorageState) {
        let schema = Schema([CompletedWorkout.self])
        let persistent = ModelConfiguration("StrengthHistory", schema: schema)
        do {
            return (try ModelContainer(for: schema, configurations: persistent), .persistent)
        } catch {
            print("[Flow] Strength history store open failed: \(error)")
            let memory = ModelConfiguration("StrengthHistoryMemory", schema: schema, isStoredInMemoryOnly: true)
            let fallback = try! ModelContainer(for: schema, configurations: memory)
            return (fallback, .inMemoryFallback(error.localizedDescription))
        }
    }
}
