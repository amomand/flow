import Foundation

/// The categories a user has explicitly chosen to put in a coach snapshot.
///
/// These are intentionally coarse product choices rather than a mirror of
/// every context field. Health metrics augment whichever history categories
/// are also selected; they never cause history to be shared on their own.
enum FlowCoachDataTier: String, Codable, CaseIterable {
    case routines
    case strengthHistory
    case cardioHistory
    case healthMetrics
}

struct FlowCoachSharingProfile: Codable, Equatable {
    static let currentSchemaVersion = 1

    /// The proposed privacy-preserving starting point: routine definitions
    /// and Flow's own derived strength history, without HealthKit metrics.
    static let recommended = FlowCoachSharingProfile(dataTiers: [.routines, .strengthHistory])

    /// Preserves the pre-envelope context export for local/manual uses.
    static let allAvailable = FlowCoachSharingProfile(dataTiers: FlowCoachDataTier.allCases)

    let schemaVersion: Int
    let dataTiers: [FlowCoachDataTier]

    init(
        schemaVersion: Int = FlowCoachSharingProfile.currentSchemaVersion,
        dataTiers: [FlowCoachDataTier]
    ) {
        self.schemaVersion = schemaVersion
        let selected = Set(dataTiers)
        self.dataTiers = FlowCoachDataTier.allCases.filter(selected.contains)
    }

    func includes(_ tier: FlowCoachDataTier) -> Bool {
        dataTiers.contains(tier)
    }
}

/// What this build of Flow can actually apply, declared to the bridge with
/// every snapshot.
///
/// Validation runs in the bridge; apply runs here. Those are different
/// machines on different release cycles, so a bridge that accepts an operation
/// this build has never heard of would hand the coach a patch that fails at
/// the last step, which is exactly the "find out by rejection" problem the
/// capability list exists to remove. The bridge advertises the intersection of
/// what it accepts and what this says.
struct FlowCoachDeviceCapabilities: Codable, Equatable {
    let patchSchemaVersions: [Int]
    let operationKinds: [String]

    static var current: FlowCoachDeviceCapabilities {
        FlowCoachDeviceCapabilities(
            patchSchemaVersions: FlowRoutinePatch.supportedSchemaVersions.sorted(),
            operationKinds: FlowRoutinePatchOperation.Kind.allCases.map(\.rawValue)
        )
    }
}

/// A short-lived, explicitly scoped copy of Flow's coach context.
///
/// Every construction gets a new identity. `contextId` correlates later
/// proposals with exactly the snapshot the assistant read; it is not an
/// authentication credential.
struct FlowCoachSnapshotEnvelope: Codable {
    static let defaultLifetime: TimeInterval = 24 * 60 * 60

    let contextId: UUID
    let createdAt: Date
    let expiresAt: Date
    let sharingProfile: FlowCoachSharingProfile
    let deviceCapabilities: FlowCoachDeviceCapabilities
    let context: FlowCoachContext

    private init(
        contextId: UUID,
        createdAt: Date,
        expiresAt: Date,
        sharingProfile: FlowCoachSharingProfile,
        deviceCapabilities: FlowCoachDeviceCapabilities,
        context: FlowCoachContext
    ) {
        self.contextId = contextId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.sharingProfile = sharingProfile
        self.deviceCapabilities = deviceCapabilities
        self.context = context
    }

    static func make(
        routines: [Routine],
        strengthWorkouts: [CompletedWorkout],
        cardioWorkouts: [Run],
        sharingProfile: FlowCoachSharingProfile = .recommended,
        createdAt: Date = Date(),
        constraintsNotes: String? = nil,
        strengthLimit: Int = 10,
        cardioLimit: Int = 12
    ) -> FlowCoachSnapshotEnvelope {
        FlowCoachSnapshotEnvelope(
            contextId: UUID(),
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(defaultLifetime),
            sharingProfile: sharingProfile,
            deviceCapabilities: .current,
            context: FlowCoachContext.make(
                routines: routines,
                strengthWorkouts: strengthWorkouts,
                cardioWorkouts: cardioWorkouts,
                generatedAt: createdAt,
                constraintsNotes: constraintsNotes,
                strengthLimit: strengthLimit,
                cardioLimit: cardioLimit,
                sharingProfile: sharingProfile
            )
        )
    }

    func jsonString() -> String? {
        let encoder = FlowRoutineExchange.encoder()
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct FlowCoachContext: Codable {
    /// Schema 2 splits routine revision identity: `routineContentHashByRoutineId`
    /// covers the editable structure a patch pins to (`baseContentHash`), and
    /// `routineStateHashByRoutineId` covers non-structural state such as the
    /// current phase. Schema 1 exported a single whole-routine hash.
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let generatedAt: Date
    let app: String
    let routines: [Routine]
    let currentPhaseByRoutineId: [String: String]
    let routineContentHashByRoutineId: [String: String]
    let routineStateHashByRoutineId: [String: String]
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
        cardioLimit: Int = 12,
        sharingProfile: FlowCoachSharingProfile = .allAvailable
    ) -> FlowCoachContext {
        let includesRoutines = sharingProfile.includes(.routines)
        let includesStrength = sharingProfile.includes(.strengthHistory)
        let includesCardio = sharingProfile.includes(.cardioHistory)
        let includesHealthMetrics = sharingProfile.includes(.healthMetrics)
        let sharedRoutines = includesRoutines ? routines : []
        let currentPhaseByRoutineId = Dictionary(
            uniqueKeysWithValues: sharedRoutines.map { ($0.id.uuidString, $0.currentPhase.rawValue) }
        )
        let routineContentHashByRoutineId = Dictionary(
            uniqueKeysWithValues: sharedRoutines.map { ($0.id.uuidString, FlowRoutineRevision.contentHash(for: $0)) }
        )
        let routineStateHashByRoutineId = Dictionary(
            uniqueKeysWithValues: sharedRoutines.map { ($0.id.uuidString, FlowRoutineRevision.stateHash(for: $0)) }
        )
        let strength: [FlowCoachStrengthSummary] = if includesStrength {
            strengthWorkouts
                .sorted { $0.endedAt > $1.endedAt }
                .prefix(strengthLimit)
                .map { FlowCoachStrengthSummary(workout: $0, includesHealthMetrics: includesHealthMetrics) }
        } else {
            []
        }
        let cardio: [FlowCoachCardioSummary] = if includesCardio {
            cardioWorkouts
                .sorted { $0.startDate > $1.startDate }
                .prefix(cardioLimit)
                .map { FlowCoachCardioSummary(run: $0, includesHealthMetrics: includesHealthMetrics) }
        } else {
            []
        }

        let constraints = FlowCoachConstraints(notes: constraintsNotes)

        return FlowCoachContext(
            schemaVersion: currentSchemaVersion,
            generatedAt: generatedAt,
            app: "Flow",
            routines: sharedRoutines,
            currentPhaseByRoutineId: currentPhaseByRoutineId,
            routineContentHashByRoutineId: routineContentHashByRoutineId,
            routineStateHashByRoutineId: routineStateHashByRoutineId,
            recentStrengthSummary: Array(strength),
            recentCardioSummary: Array(cardio),
            constraints: constraints.isEmpty ? nil : constraints
        )
    }

    func jsonString() -> String? {
        let encoder = FlowRoutineExchange.encoder()
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

    init(workout: CompletedWorkout, includesHealthMetrics: Bool = true) {
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
        appleWatchMetrics = includesHealthMetrics ? FlowCoachStrengthMetrics(workout: workout) : nil
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

    init(run: Run, includesHealthMetrics: Bool = true) {
        date = run.startDate
        activity = run.activity.rawValue
        distanceMetres = run.distanceMetres
        durationSeconds = run.durationSeconds
        elevationGainMetres = run.elevationGainMetres
        averageHeartRate = includesHealthMetrics ? run.avgHeartRate : nil
        maxHeartRate = includesHealthMetrics ? run.maxHeartRate : nil
    }
}
