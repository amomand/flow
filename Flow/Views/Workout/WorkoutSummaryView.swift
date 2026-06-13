import SwiftUI

struct WorkoutSummaryView: View {
    @Environment(\.theme) private var theme
    let session: WorkoutSession
    let store: RoutineStore
    let historyStore: StrengthHistoryStore
    let onDone: () -> Void

    @State private var copied = false
    @State private var adjustmentDecision: AdjustmentDecision = .proposed
    @State private var didRecordInitialHistory = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("// WORKOUT COMPLETE")
                .terminalFont(18, weight: .bold)
                .foregroundColor(theme.green)
                .padding(.top, 24)

            Text(session.routine.name)
                .terminalFont(13)
                .foregroundColor(theme.comment)
                .padding(.top, 4)

            let duration = session.formattedDuration
            Text("Duration: \(duration)")
                .terminalFont(13)
                .foregroundColor(theme.comment)
                .padding(.top, 2)

            Divider()
                .background(theme.comment.opacity(0.3))
                .padding(.vertical, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let fails = session.results.filter { $0.rating == .couldNotComplete }
                    let easies = session.results.filter { $0.rating == .tooEasy }

                    if let completedWorkout, completedWorkout.hasHealthKitMetrics {
                        SummaryHealthKitMetrics(workout: completedWorkout)
                    }

                    if fails.isEmpty && easies.isEmpty && session.adjustments.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Text("✅")
                                    .font(.system(size: 40))
                                Text("All sets completed as expected")
                                    .terminalFont(14)
                                    .foregroundColor(theme.green)
                                Text("No adjustments needed.")
                                    .terminalFont(12)
                                    .foregroundColor(theme.comment)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    } else {
                        if !fails.isEmpty {
                            Text("❌ NEEDS ATTENTION")
                                .terminalFont(14, weight: .bold)
                                .foregroundColor(theme.red)

                            let grouped = Dictionary(grouping: fails) { $0.exerciseName }
                            ForEach(grouped.keys.sorted(), id: \.self) { name in
                                if let sets = grouped[name] {
                                    SummaryExerciseRow(
                                        name: name,
                                        sets: sets,
                                        totalSets: session.results.filter { $0.exerciseName == name }.count,
                                        color: theme.red
                                    )
                                }
                            }
                        }

                        if !easies.isEmpty {
                            if !fails.isEmpty {
                                Divider()
                                    .background(theme.comment.opacity(0.3))
                                    .padding(.vertical, 4)
                            }

                            Text("🪶 TOO EASY — CONSIDER PROGRESSING")
                                .terminalFont(14, weight: .bold)
                                .foregroundColor(theme.yellow)

                            let grouped = Dictionary(grouping: easies) { $0.exerciseName }
                            ForEach(grouped.keys.sorted(), id: \.self) { name in
                                if let sets = grouped[name] {
                                    SummaryExerciseRow(
                                        name: name,
                                        sets: sets,
                                        totalSets: session.results.filter { $0.exerciseName == name }.count,
                                        color: theme.yellow
                                    )
                                }
                            }
                        }

                        if !session.adjustments.isEmpty {
                            Divider()
                                .background(theme.comment.opacity(0.3))
                                .padding(.vertical, 4)

                            Text("📐 ADJUSTMENTS \(adjustmentDecision.displayName.uppercased())")
                                .terminalFont(14, weight: .bold)
                                .foregroundColor(theme.blue)

                            ForEach(session.adjustments) { adj in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(adj.exerciseName)
                                            .terminalFont(14, weight: .bold)
                                            .foregroundColor(theme.fg)
                                        Text("\(adj.field): \(adj.oldValue) → \(adj.newValue)")
                                            .terminalFont(12)
                                            .foregroundColor(theme.blue)
                                    }
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .terminalCard()
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                if needsAdjustmentDecision {
                    HStack(spacing: 10) {
                        Button {
                            applyAdjustments()
                        } label: {
                            Text("[ APPLY ]")
                        }
                        .buttonStyle(TerminalButtonStyle(color: theme.green))

                        Button {
                            skipAdjustments()
                        } label: {
                            Text("[ SKIP ]")
                        }
                        .buttonStyle(TerminalButtonStyle(color: theme.yellow))
                    }
                }

                Button {
                    UIPasteboard.general.string = summaryMarkdown
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                } label: {
                    Text(copied ? "[ ✓ COPIED ]" : "[ COPY SUMMARY ]")
                }
                .buttonStyle(TerminalButtonStyle(color: copied ? theme.green : theme.blue))

                Button {
                    onDone()
                } label: {
                    Text("[ DONE ]")
                }
                .buttonStyle(TerminalButtonStyle(color: theme.comment))
                .disabled(needsAdjustmentDecision)
                .opacity(needsAdjustmentDecision ? 0.45 : 1)
            }
            .padding(.bottom, 32)
        }
        .onAppear {
            guard !didRecordInitialHistory else { return }
            didRecordInitialHistory = true
            adjustmentDecision = session.adjustments.isEmpty ? .none : .proposed
            let workout = historyStore.record(session: session, decision: adjustmentDecision)
            Task {
                await historyStore.syncHealthKitMetrics(for: workout.id)
            }
        }
    }

    private var completedWorkout: CompletedWorkout? {
        historyStore.workouts.first { $0.id == session.id }
    }

    private var needsAdjustmentDecision: Bool {
        !session.adjustments.isEmpty && adjustmentDecision == .proposed
    }

    private var summaryMarkdown: String {
        var markdown = session.generateSummaryMarkdown(adjustmentDecision: adjustmentDecision)
        guard let completedWorkout, completedWorkout.hasHealthKitMetrics else { return markdown }

        markdown += "\n\n### Apple Watch\n"
        if let activity = completedWorkout.healthKitWorkoutActivityName {
            markdown += "- **Workout:** \(activity)\n"
        }
        if let duration = completedWorkout.formattedHealthKitDuration {
            markdown += "- **Watch duration:** \(duration)\n"
        }
        if let energy = completedWorkout.formattedActiveEnergy {
            markdown += "- **Active energy:** \(energy)\n"
        }
        if let exerciseTime = completedWorkout.formattedAppleExerciseTime {
            markdown += "- **Exercise time:** \(exerciseTime)\n"
        }
        if let averageHeartRate = completedWorkout.formattedAverageHeartRate {
            markdown += "- **Average heart rate:** \(averageHeartRate)\n"
        }
        if let maxHeartRate = completedWorkout.formattedMaxHeartRate {
            markdown += "- **Max heart rate:** \(maxHeartRate)\n"
        }
        if let effort = completedWorkout.formattedEffortScore {
            markdown += "- **Effort:** \(effort)\n"
        }
        if let mets = completedWorkout.formattedAverageMETs {
            markdown += "- **Average METs:** \(mets)\n"
        }

        return markdown
    }

    private func applyAdjustments() {
        var updated = session.routine
        session.applyAdjustments(to: &updated)
        store.updateRoutine(updated)
        adjustmentDecision = .applied
        historyStore.record(session: session, decision: .applied, appliedAdjustments: session.adjustments)
    }

    private func skipAdjustments() {
        adjustmentDecision = .skipped
        historyStore.record(session: session, decision: .skipped)
    }
}

private struct SummaryHealthKitMetrics: View {
    @Environment(\.theme) private var theme
    let workout: CompletedWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("APPLE WATCH")
                    .terminalFont(14, weight: .bold)
                    .foregroundColor(theme.purple)
                Spacer()
                if let duration = workout.formattedHealthKitDuration {
                    Text(duration)
                        .terminalFont(12, weight: .bold)
                        .foregroundColor(theme.comment)
                }
            }

            if let activity = workout.healthKitWorkoutActivityName {
                Text(activity)
                    .terminalFont(12)
                    .foregroundColor(theme.comment)
            }

            HealthKitMetricBadges(workout: workout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .terminalCard()
    }
}

struct HealthKitMetricBadges: View {
    @Environment(\.theme) private var theme
    let workout: CompletedWorkout

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(workout.healthKitMetricBadges, id: \.self) { text in
                Text(text)
                    .terminalFont(11, weight: .bold)
                    .foregroundColor(theme.fg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.darkCard)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(theme.purple.opacity(0.35), lineWidth: 1)
                            )
                    )
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if maxWidth > 0 && x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + (x > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct SummaryExerciseRow: View {
    @Environment(\.theme) private var theme
    let name: String
    let sets: [SetResult]
    let totalSets: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .terminalFont(14, weight: .bold)
                .foregroundColor(theme.fg)

            if sets.count == totalSets {
                Text("All sets")
                    .terminalFont(12)
                    .foregroundColor(color)
            } else {
                let setNums = sets.map { "Set \($0.setNumber)" }.joined(separator: ", ")
                Text(setNums)
                    .terminalFont(12)
                    .foregroundColor(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .terminalCard()
    }
}
