import Foundation
import HealthKit
import CoreLocation

enum HealthKitError: Error {
    case notAvailable
    case unauthorized
}

final class HealthKitService {
    static let shared = HealthKitService()
    let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        var s: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling)
        ]
        if let active = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            s.insert(active)
        }
        return s
    }

    func isAvailable() -> Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard isAvailable() else { throw HealthKitError.notAvailable }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    struct WorkoutChanges {
        let added: [HKWorkout]
        let deletedUUIDs: [UUID]
        let newAnchor: HKQueryAnchor?
    }

    /// Additions, edits and deletions to workouts of the requested activity since a saved anchor.
    func fetchWorkoutChanges(activity: CardioActivity, anchor: HKQueryAnchor?) async throws -> WorkoutChanges {
        let activityPred = HKQuery.predicateForWorkouts(with: activity.healthKitType)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(),
                predicate: activityPred,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deleted, newAnchor, error in
                if let error { cont.resume(throwing: error); return }
                let added = (samples as? [HKWorkout]) ?? []
                let deletedUUIDs = (deleted ?? []).map(\.uuid)
                cont.resume(returning: WorkoutChanges(added: added, deletedUUIDs: deletedUUIDs, newAnchor: newAnchor))
            }
            store.execute(q)
        }
    }

    /// Total distance for a workout, in metres. Prefers statistics over the deprecated totalDistance.
    func distanceMetres(for workout: HKWorkout, activity: CardioActivity) -> Double {
        let type = HKQuantityType(activity.distanceQuantityIdentifier)
        if let qty = workout.statistics(for: type)?.sumQuantity() {
            return qty.doubleValue(for: .meter())
        }
        return 0
    }

    /// Elevation gain in metres from workout metadata, if Apple Watch recorded it.
    func elevationGainMetres(for workout: HKWorkout) -> Double? {
        if let q = workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity {
            return q.doubleValue(for: .meter())
        }
        return nil
    }

    /// Look up a workout by its HealthKit UUID.
    func fetchWorkout(uuid: UUID) async throws -> HKWorkout? {
        let pred = HKQuery.predicateForObjects(with: [uuid])
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: pred, limit: 1, sortDescriptors: nil) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkout])?.first)
            }
            store.execute(q)
        }
    }

    /// Fetch all route segments attached to a workout, then resolve their CLLocations.
    func fetchRoute(for workout: HKWorkout) async throws -> [CLLocation] {
        let pred = HKQuery.predicateForObjects(from: workout)
        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(q)
        }

        var segments: [[CLLocation]] = []
        for route in routes.sorted(by: { $0.startDate < $1.startDate }) {
            segments.append(try await locations(for: route))
        }

        return segments
            .flatMap { $0 }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func locations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { cont in
            var collected: [CLLocation] = []
            let q = HKWorkoutRouteQuery(route: route) { _, locs, done, error in
                if let error { cont.resume(throwing: error); return }
                if let locs { collected.append(contentsOf: locs) }
                if done { cont.resume(returning: collected) }
            }
            store.execute(q)
        }
    }

    /// Average HR (bpm) from a workout's statistics if available.
    func averageHeartRate(for workout: HKWorkout) -> Double? {
        let type = HKQuantityType(.heartRate)
        guard let q = workout.statistics(for: type)?.averageQuantity() else { return nil }
        return q.doubleValue(for: HKUnit(from: "count/min"))
    }

    func maxHeartRate(for workout: HKWorkout) -> Double? {
        let type = HKQuantityType(.heartRate)
        guard let q = workout.statistics(for: type)?.maximumQuantity() else { return nil }
        return q.doubleValue(for: HKUnit(from: "count/min"))
    }
}

private extension CardioActivity {
    var healthKitType: HKWorkoutActivityType {
        switch self {
        case .running: return .running
        case .cycling: return .cycling
        }
    }

    var distanceQuantityIdentifier: HKQuantityTypeIdentifier {
        switch self {
        case .running: return .distanceWalkingRunning
        case .cycling: return .distanceCycling
        }
    }
}
