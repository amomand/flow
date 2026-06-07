import SwiftUI

struct WorkoutSummaryView: View {
    @Environment(\.theme) private var theme
    let session: WorkoutSession
    let store: RoutineStore
    let onDone: () -> Void

    @State private var copied = false
    @State private var adjustmentsApplied = false

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

            let duration = formattedDuration
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

                            Text("📐 ADJUSTMENTS APPLIED")
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
                Button {
                    UIPasteboard.general.string = session.generateSummaryMarkdown()
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
            }
            .padding(.bottom, 32)
        }
        .onAppear {
            if !adjustmentsApplied && !session.adjustments.isEmpty {
                adjustmentsApplied = true
                var updated = session.routine
                session.applyAdjustments(to: &updated)
                store.updateRoutine(updated)
            }
        }
    }

    private var formattedDuration: String {
        let elapsed = Int(Date().timeIntervalSince(session.startedAt))
        let mins = elapsed / 60
        let secs = elapsed % 60
        return String(format: "%d:%02d", mins, secs)
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
