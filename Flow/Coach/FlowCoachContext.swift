import Foundation

struct FlowCoachContext: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let app: String
    let routines: [Routine]
    let currentPhaseByRoutineId: [String: String]
    let routineHashByRoutineId: [String: String]
    let recentStrengthSummary: [FlowCoachStrengthSummary]
    let recentCardioSummary: [FlowCoachCardioSummary]
    let constraints: FlowCoachConstraints?

    static func make(
        routines: [Routine],
        strengthWorkouts: [CompletedWorkout],
        cardioWorkouts: [Run],
        generatedAt: Date = Date(),
        constraintsNotes: String? = nil,
        strengthLimit: Int = 10,
        cardioLimit: Int = 12
    ) -> FlowCoachContext {
        let currentPhaseByRoutineId = Dictionary(
            uniqueKeysWithValues: routines.map { ($0.id.uuidString, $0.currentPhase.rawValue) }
        )
        let routineHashByRoutineId = Dictionary(
            uniqueKeysWithValues: routines.map { ($0.id.uuidString, FlowRoutineRevision.hash(for: $0)) }
        )
        let strength = strengthWorkouts
            .sorted { $0.endedAt > $1.endedAt }
            .prefix(strengthLimit)
            .map(FlowCoachStrengthSummary.init)
        let cardio = cardioWorkouts
            .sorted { $0.startDate > $1.startDate }
            .prefix(cardioLimit)
            .map(FlowCoachCardioSummary.init)

        let constraints = FlowCoachConstraints(notes: constraintsNotes)

        return FlowCoachContext(
            schemaVersion: 1,
            generatedAt: generatedAt,
            app: "Flow",
            routines: routines,
            currentPhaseByRoutineId: currentPhaseByRoutineId,
            routineHashByRoutineId: routineHashByRoutineId,
            recentStrengthSummary: Array(strength),
            recentCardioSummary: Array(cardio),
            constraints: constraints.isEmpty ? nil : constraints
        )
    }

    func jsonString() -> String? {
        let encoder = FlowCoachCoding.encoder()
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct FlowCoachConstraints: Codable, Equatable {
    let notes: String?

    init(notes: String?) {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = trimmed?.isEmpty == false ? trimmed : nil
    }

    var isEmpty: Bool {
        notes == nil
    }
}

struct FlowCoachStrengthSummary: Codable {
    let date: Date
    let routineId: UUID
    let routineName: String
    let phase: WorkoutPhase
    let durationSeconds: Double
    let ratings: FlowCoachRatingSummary
    let adjustmentDecision: AdjustmentDecision
    let proposedAdjustments: [CompletedRoutineAdjustment]
    let appliedAdjustments: [CompletedRoutineAdjustment]
    let notableFailures: [FlowCoachSetNote]
    let notableEasySets: [FlowCoachSetNote]
    let appleWatchMetrics: FlowCoachStrengthMetrics?

    init(workout: CompletedWorkout) {
        let setResults = workout.setResults
        date = workout.endedAt
        routineId = workout.routineId
        routineName = workout.routineName
        phase = workout.phase
        durationSeconds = workout.durationSeconds
        ratings = FlowCoachRatingSummary(results: setResults)
        adjustmentDecision = workout.adjustmentDecision
        proposedAdjustments = workout.proposedAdjustments
        appliedAdjustments = workout.appliedAdjustments
        notableFailures = setResults
            .filter { $0.rating == .couldNotComplete }
            .prefix(8)
            .map(FlowCoachSetNote.init)
        notableEasySets = setResults
            .filter { $0.rating == .tooEasy }
            .prefix(8)
            .map(FlowCoachSetNote.init)
        appleWatchMetrics = FlowCoachStrengthMetrics(workout: workout)
    }
}

struct FlowCoachRatingSummary: Codable, Equatable {
    let failed: Int
    let good: Int
    let easy: Int

    init(results: [CompletedSetResult]) {
        failed = results.filter { $0.rating == .couldNotComplete }.count
        good = results.filter { $0.rating == .good }.count
        easy = results.filter { $0.rating == .tooEasy }.count
    }
}

struct FlowCoachSetNote: Codable, Equatable {
    let exerciseId: UUID
    let exerciseName: String
    let setNumber: Int
    let side: WorkoutSide?
    let rating: SetRating

    init(result: CompletedSetResult) {
        exerciseId = result.exerciseId
        exerciseName = result.exerciseName
        setNumber = result.setNumber
        side = result.side
        rating = result.rating
    }
}

struct FlowCoachStrengthMetrics: Codable, Equatable {
    let durationSeconds: Double?
    let activeEnergyKilocalories: Double?
    let appleExerciseTimeSeconds: Double?
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let workoutEffortScore: Double?
    let estimatedWorkoutEffortScore: Double?
    let averageMETs: Double?

    init?(workout: CompletedWorkout) {
        guard workout.hasHealthKitMetrics else { return nil }
        durationSeconds = workout.healthKitDurationSeconds
        activeEnergyKilocalories = workout.activeEnergyKilocalories
        appleExerciseTimeSeconds = workout.appleExerciseTimeSeconds
        averageHeartRate = workout.averageHeartRate
        maxHeartRate = workout.maxHeartRate
        workoutEffortScore = workout.workoutEffortScore
        estimatedWorkoutEffortScore = workout.estimatedWorkoutEffortScore
        averageMETs = workout.averageMETs
    }
}

struct FlowCoachCardioSummary: Codable, Equatable {
    let date: Date
    let activity: String
    let distanceMetres: Double
    let durationSeconds: Double
    let elevationGainMetres: Double?
    let averageHeartRate: Double?
    let maxHeartRate: Double?

    init(run: Run) {
        date = run.startDate
        activity = run.activity.rawValue
        distanceMetres = run.distanceMetres
        durationSeconds = run.durationSeconds
        elevationGainMetres = run.elevationGainMetres
        averageHeartRate = run.avgHeartRate
        maxHeartRate = run.maxHeartRate
    }
}

enum FlowCoachCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
