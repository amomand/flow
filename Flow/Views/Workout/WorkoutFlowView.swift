import SwiftUI
import AudioToolbox

struct WorkoutFlowView: View {
    let routine: Routine
    let store: RoutineStore
    let historyStore: StrengthHistoryStore
    let onDismiss: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: WorkoutSession
    @State private var showQuitConfirm = false
    @State private var showOverview = false
    @State private var now = Date()

    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(routine: Routine, store: RoutineStore, historyStore: StrengthHistoryStore, onDismiss: @escaping () -> Void) {
        self.routine = routine
        self.store = store
        self.historyStore = historyStore
        self.onDismiss = onDismiss
        self._session = State(initialValue: WorkoutSession(routine: routine))
    }

    private var theme: Theme {
        Theme.for(routine.currentPhase)
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()

            if session.isFinished {
                WorkoutSummaryView(session: session, store: store, historyStore: historyStore, onDone: onDismiss)
            } else if session.isResting {
                RestTimerView(
                    seconds: session.currentTimerDurationSeconds,
                    remaining: session.remainingTimerSeconds(at: now),
                    nextExerciseName: nextStepName,
                    estimatedMinutes: session.estimatedMinutesRemaining,
                    onSkip: {
                        let eventDate = Date()
                        now = eventDate
                        session.skipActiveTimer(at: eventDate)
                    },
                    onShowOverview: { showOverview = true }
                )
                .id(session.currentStepIndex)
            } else if session.isTimedExerciseActive, let step = session.currentStep {
                TimedExerciseView(
                    step: step,
                    totalSteps: session.steps.count,
                    currentIndex: session.currentStepIndex,
                    estimatedMinutes: session.estimatedMinutesRemaining,
                    seconds: session.currentTimerDurationSeconds,
                    remaining: session.remainingTimerSeconds(at: now),
                    nextLabel: nextLabel(for: step),
                    onSkip: {
                        let eventDate = Date()
                        now = eventDate
                        session.skipActiveTimer(at: eventDate)
                    },
                    onQuit: {
                        showQuitConfirm = true
                    },
                    onShowOverview: { showOverview = true }
                )
                .id(session.currentStepIndex)
            } else if let step = session.currentStep {
                ExerciseCardView(
                    step: step,
                    totalSteps: session.steps.count,
                    currentIndex: session.currentStepIndex,
                    estimatedMinutes: session.estimatedMinutesRemaining,
                    selectedRating: $session.selectedRating,
                    onComplete: {
                        let eventDate = Date()
                        now = eventDate
                        session.completeCurrentSet(completedAt: eventDate)
                    },
                    onQuit: {
                        showQuitConfirm = true
                    },
                    onShowOverview: { showOverview = true }
                )
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            syncSession(to: Date(), triggerVibration: false)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(clock) { tick in
            guard scenePhase == .active else { return }
            syncSession(to: tick, triggerVibration: true)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            syncSession(to: Date(), triggerVibration: false)
        }
        .alert("Quit Workout?", isPresented: $showQuitConfirm) {
            Button("Keep Going", role: .cancel) { }
            Button("Quit", role: .destructive) { onDismiss() }
        } message: {
            Text("Progress will be lost.")
        }
        .sheet(isPresented: $showOverview) {
            RoutineOverviewSheet(session: session)
                .environment(\.theme, theme)
        }
        .environment(\.theme, theme)
    }

    private func syncSession(to date: Date, triggerVibration: Bool) {
        now = date
        let completedTimer = session.refreshAgainstClock(now: date)
        if triggerVibration && completedTimer {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    private func nextLabel(for step: WorkoutStep) -> String {
        if step.restSeconds > 0 && session.currentStepIndex < session.steps.count - 1 {
            return "rest"
        }

        return nextStepName
    }

    private var nextStepName: String {
        guard let step = session.nextStep else { return "done!" }
        if let side = step.side {
            return "\(step.exercise.name) (\(side.displayName.lowercased()))"
        }
        return step.exercise.name
    }
}
