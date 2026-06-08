import Foundation
import SwiftData
import HealthKit

@Observable
final class SyncCoordinator {
    enum State: Equatable {
        case idle
        case syncing
        case error(String)
    }

    var state: State = .idle
    var lastSyncedAt: Date?

    private let hk = HealthKitService.shared
    private let modelContainer: ModelContainer
    private static let anchorKeyPrefix = "flow.workoutAnchor"

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    @MainActor
    func sync() async {
        guard state != .syncing else { return }
        state = .syncing

        do {
            let context = modelContainer.mainContext
            for activity in CardioActivity.allCases {
                let changes = try await hk.fetchWorkoutChanges(activity: activity, anchor: Self.loadAnchor(for: activity))

                for workout in changes.added {
                    upsert(workout: workout, activity: activity, into: context)
                }

                for id in changes.deletedUUIDs {
                    deleteRun(id: id, from: context)
                }

                if context.hasChanges {
                    try context.save()
                }

                if let newAnchor = changes.newAnchor {
                    Self.saveAnchor(newAnchor, for: activity)
                }
            }

            lastSyncedAt = Date()
            state = .idle
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    @MainActor
    private func upsert(workout w: HKWorkout, activity: CardioActivity, into context: ModelContext) {
        let id = w.uuid
        var descriptor = FetchDescriptor<Run>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let existing = try? context.fetch(descriptor).first

        let distance = hk.distanceMetres(for: w, activity: activity)
        let elevation = hk.elevationGainMetres(for: w)
        let avgHR = hk.averageHeartRate(for: w)
        let maxHR = hk.maxHeartRate(for: w)

        if let run = existing {
            let routeAffectingValuesChanged = run.startDate != w.startDate
                || run.endDate != w.endDate
                || run.distanceMetres != distance
                || run.durationSeconds != w.duration

            run.activityRawValue = activity.rawValue
            run.startDate = w.startDate
            run.endDate = w.endDate
            run.distanceMetres = distance
            run.durationSeconds = w.duration
            run.elevationGainMetres = elevation
            run.avgHeartRate = avgHR
            run.maxHeartRate = maxHR
            if routeAffectingValuesChanged {
                run.clearCachedRoute()
            }
        } else {
            context.insert(Run(
                id: id,
                activity: activity,
                startDate: w.startDate,
                endDate: w.endDate,
                distanceMetres: distance,
                durationSeconds: w.duration,
                elevationGainMetres: elevation,
                avgHeartRate: avgHR,
                maxHeartRate: maxHR
            ))
        }
    }

    @MainActor
    private func deleteRun(id: UUID, from context: ModelContext) {
        var descriptor = FetchDescriptor<Run>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let run = try? context.fetch(descriptor).first {
            context.delete(run)
        }
    }

    private static func anchorKey(for activity: CardioActivity) -> String {
        "\(anchorKeyPrefix).\(activity.rawValue)"
    }

    private static func loadAnchor(for activity: CardioActivity) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: anchorKey(for: activity)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private static func saveAnchor(_ anchor: HKQueryAnchor, for activity: CardioActivity) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: anchorKey(for: activity))
    }
}
