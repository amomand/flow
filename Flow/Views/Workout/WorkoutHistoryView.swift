import SwiftUI

struct WorkoutHistoryView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let historyStore: StrengthHistoryStore

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()

                if historyStore.workouts.isEmpty {
                    VStack(spacing: 10) {
                        Text("$ ls workouts/")
                            .terminalFont(16, weight: .bold)
                            .foregroundColor(theme.green)
                        Text("// no completed strength workouts yet")
                            .terminalFont(12)
                            .foregroundColor(theme.comment)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(historyStore.workouts) { workout in
                                WorkoutHistoryRow(workout: workout)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("workout history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("[ done ]") { dismiss() }
                        .terminalFont(12, weight: .bold)
                        .foregroundColor(theme.cyan)
                }
            }
            .toolbarBackground(theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear { historyStore.reload() }
            .task {
                await historyStore.syncHealthKitMetricsForRecentWorkouts()
            }
        }
    }
}

private struct WorkoutHistoryRow: View {
    @Environment(\.theme) private var theme
    let workout: CompletedWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(workout.routineName)
                    .terminalFont(14, weight: .bold)
                    .foregroundColor(theme.fg)
                Spacer()
                Text(workout.phase.displayName.uppercased())
                    .terminalFont(10, weight: .bold)
                    .foregroundColor(theme.bg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(workout.phase.accentColor))
            }

            HStack(spacing: 8) {
                metric(workout.endedAt.formatted(.dateTime.day().month(.abbreviated).year()), color: theme.cyan)
                dot
                metric(workout.formattedDuration, color: theme.fg)
                dot
                metric("\(workout.setResults.count) sets", color: theme.fg)
            }
            .terminalFont(12)

            if !workout.proposedAdjustments.isEmpty {
                Text("adjustments: \(workout.adjustmentDecision.displayName.lowercased())")
                    .terminalFont(12)
                    .foregroundColor(workout.adjustmentDecision == .applied ? theme.green : theme.comment)
            }

            if workout.hasHealthKitMetrics {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("watch")
                            .terminalFont(11, weight: .bold)
                            .foregroundColor(theme.purple)
                        if let duration = workout.formattedHealthKitDuration {
                            Text(duration)
                                .terminalFont(11)
                                .foregroundColor(theme.comment)
                        }
                        if let activity = workout.healthKitWorkoutActivityName {
                            Text(activity.lowercased())
                                .terminalFont(11)
                                .foregroundColor(theme.comment)
                        }
                    }
                    HealthKitMetricBadges(workout: workout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .terminalCard()
    }

    private var dot: some View {
        Text("·").foregroundColor(theme.comment)
    }

    private func metric(_ text: String, color: Color) -> some View {
        Text(text).foregroundColor(color)
    }
}
