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
            HKQuantityType(.distanceWalkingRunning)
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

    /// Fetch all running workouts ending after `since`.
    func fetchRunningWorkouts(since: Date) async throws -> [HKWorkout] {
        let workoutType = HKObjectType.workoutType()
        let runPred = HKQuery.predicateForWorkouts(with: .running)
        let datePred = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [runPred, datePred])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: workoutType, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
    }

    /// Total distance for a workout, in metres. Prefers statistics over the deprecated totalDistance.
    func distanceMetres(for workout: HKWorkout) -> Double {
        let type = HKQuantityType(.distanceWalkingRunning)
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

    /// Fetch heart rate samples that fall within the workout's time range.
    func fetchHeartRateSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] {
        let pred = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKQuantityType(.heartRate), predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
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
