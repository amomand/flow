import Foundation
import HealthKit
import CoreLocation

enum HealthKitError: Error {
    case notAvailable
    case unauthorized
}

struct HealthKitStrengthWorkoutMetrics: Equatable {
    let workoutId: UUID
    let activityName: String
    let startDate: Date
    let endDate: Date
    let durationSeconds: Double
    let activeEnergyKilocalories: Double?
    let appleExerciseTimeSeconds: Double?
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let workoutEffortScore: Double?
    let estimatedWorkoutEffortScore: Double?
    let averageMETs: Double?
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
            HKQuantityType(.distanceCycling),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.physicalEffort),
            HKQuantityType(.workoutEffortScore),
            HKQuantityType(.estimatedWorkoutEffortScore)
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

    func fetchBestStrengthWorkout(
        startedAt: Date,
        endedAt: Date,
        tolerance: TimeInterval = 30 * 60
    ) async throws -> HealthKitStrengthWorkoutMetrics? {
        guard isAvailable() else { throw HealthKitError.notAvailable }

        let searchStart = startedAt.addingTimeInterval(-tolerance)
        let searchEnd = endedAt.addingTimeInterval(tolerance)
        let datePredicate = HKQuery.predicateForSamples(withStart: searchStart, end: searchEnd)
        let activityPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: strengthActivityTypes.map {
            HKQuery.predicateForWorkouts(with: $0)
        })
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [datePredicate, activityPredicate])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 20,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }

        guard let best = workouts
            .filter({ Self.isPlausibleStrengthMatch($0, startedAt: startedAt, endedAt: endedAt) })
            .max(by: {
                Self.strengthMatchScore($0, startedAt: startedAt, endedAt: endedAt)
                    < Self.strengthMatchScore($1, startedAt: startedAt, endedAt: endedAt)
            })
        else {
            return nil
        }

        return strengthMetrics(for: best)
    }

    func strengthMetrics(for workout: HKWorkout) -> HealthKitStrengthWorkoutMetrics {
        HealthKitStrengthWorkoutMetrics(
            workoutId: workout.uuid,
            activityName: Self.strengthActivityName(for: workout.workoutActivityType),
            startDate: workout.startDate,
            endDate: workout.endDate,
            durationSeconds: workout.duration,
            activeEnergyKilocalories: sumQuantity(.activeEnergyBurned, in: workout, unit: .kilocalorie()),
            appleExerciseTimeSeconds: sumQuantity(.appleExerciseTime, in: workout, unit: .second()),
            averageHeartRate: averageHeartRate(for: workout),
            maxHeartRate: maxHeartRate(for: workout),
            workoutEffortScore: averageOrMaximumQuantity(.workoutEffortScore, in: workout, unit: .count()),
            estimatedWorkoutEffortScore: averageOrMaximumQuantity(.estimatedWorkoutEffortScore, in: workout, unit: .count()),
            averageMETs: averageMETs(for: workout)
        )
    }

    private var strengthActivityTypes: [HKWorkoutActivityType] {
        [.traditionalStrengthTraining, .functionalStrengthTraining]
    }

    private func sumQuantity(_ identifier: HKQuantityTypeIdentifier, in workout: HKWorkout, unit: HKUnit) -> Double? {
        let type = HKQuantityType(identifier)
        return workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: unit)
    }

    private func averageOrMaximumQuantity(_ identifier: HKQuantityTypeIdentifier, in workout: HKWorkout, unit: HKUnit) -> Double? {
        let type = HKQuantityType(identifier)
        let stats = workout.statistics(for: type)
        return stats?.averageQuantity()?.doubleValue(for: unit)
            ?? stats?.maximumQuantity()?.doubleValue(for: unit)
    }

    private func averageMETs(for workout: HKWorkout) -> Double? {
        let metsUnit = HKUnit(from: "kcal/(kg*hr)")
        if let average = workout.metadata?[HKMetadataKeyAverageMETs] as? HKQuantity {
            return average.doubleValue(for: metsUnit)
        }
        return averageOrMaximumQuantity(.physicalEffort, in: workout, unit: metsUnit)
    }

    private static func isPlausibleStrengthMatch(_ workout: HKWorkout, startedAt: Date, endedAt: Date) -> Bool {
        let sessionDuration = max(endedAt.timeIntervalSince(startedAt), 1)
        let overlap = overlapSeconds(workout, startedAt: startedAt, endedAt: endedAt)
        let minOverlap = min(5 * 60, sessionDuration * 0.25)

        if overlap >= minOverlap {
            return true
        }

        let startDelta = abs(workout.startDate.timeIntervalSince(startedAt))
        let endDelta = abs(workout.endDate.timeIntervalSince(endedAt))
        return startDelta <= 10 * 60 && endDelta <= 10 * 60
    }

    private static func strengthMatchScore(_ workout: HKWorkout, startedAt: Date, endedAt: Date) -> Double {
        let overlap = overlapSeconds(workout, startedAt: startedAt, endedAt: endedAt)
        let startPenalty = abs(workout.startDate.timeIntervalSince(startedAt)) * 0.1
        let endPenalty = abs(workout.endDate.timeIntervalSince(endedAt)) * 0.1
        let durationPenalty = abs(workout.duration - endedAt.timeIntervalSince(startedAt)) * 0.05
        return overlap - startPenalty - endPenalty - durationPenalty
    }

    private static func overlapSeconds(_ workout: HKWorkout, startedAt: Date, endedAt: Date) -> Double {
        max(0, min(workout.endDate, endedAt).timeIntervalSince(max(workout.startDate, startedAt)))
    }

    private static func strengthActivityName(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .functionalStrengthTraining: return "Functional Strength"
        case .traditionalStrengthTraining: return "Traditional Strength"
        default: return "Strength"
        }
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
