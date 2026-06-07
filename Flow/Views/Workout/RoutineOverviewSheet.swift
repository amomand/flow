import SwiftUI

struct RoutineOverviewSheet: View {
    @Environment(\.theme) private var theme
    let session: WorkoutSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("// ROUTINE OVERVIEW")
                        .terminalFont(14, weight: .bold)
                        .foregroundColor(theme.purple)
                    Spacer()
                    PhaseChip(phase: session.routine.currentPhase)
                    Button {
                        dismiss()
                    } label: {
                        Text("[ ✕ ]")
                            .terminalFont(14, weight: .bold)
                            .foregroundColor(theme.comment)
                    }
                }
                .padding()

                Divider()
                    .background(theme.comment.opacity(0.3))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        var lastSection = ""

                        ForEach(Array(session.steps.enumerated()), id: \.element.id) { index, step in
                            let isNewSection = step.sectionName != lastSection

                            // Section header
                            if isNewSection {
                                let _ = (lastSection = step.sectionName)
                                Text("// \(step.sectionName.uppercased())")
                                    .terminalFont(12, weight: .bold)
                                    .foregroundColor(theme.purple)
                                    .padding(.horizontal)
                                    .padding(.top, 16)
                                    .padding(.bottom, 4)
                            }

                            OverviewStepRow(
                                step: step,
                                index: index,
                                currentIndex: session.currentStepIndex
                            )
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct PhaseChip: View {
    let phase: WorkoutPhase

    var body: some View {
        Text(phase.displayName.uppercased())
            .terminalFont(10, weight: .bold)
            .foregroundColor(Theme.base.bg) // fixed dark text for contrast on saturated accent pill
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(phase.accentColor)
            )
    }
}

struct OverviewStepRow: View {
    @Environment(\.theme) private var theme
    let step: WorkoutStep
    let index: Int
    let currentIndex: Int

    private var isCompleted: Bool { index < currentIndex }
    private var isCurrent: Bool { index == currentIndex }

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            if isCompleted {
                Image(systemName: "checkmark")
                    .foregroundColor(theme.green.opacity(0.5))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .frame(width: 20)
            } else if isCurrent {
                Image(systemName: "chevron.right")
                    .foregroundColor(theme.blue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .frame(width: 20)
            } else {
                Color.clear.frame(width: 20, height: 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(step.exercise.name)
                    .terminalFont(13, weight: isCurrent ? .bold : .regular)
                    .foregroundColor(isCompleted ? theme.comment.opacity(0.5) : (isCurrent ? theme.fg : theme.fg))
                    .strikethrough(isCompleted)

                HStack(spacing: 8) {
                    Text("Set \(step.setNumber)/\(step.exercise.sets)")
                        .terminalFont(11)
                        .foregroundColor(isCompleted ? theme.comment.opacity(0.3) : theme.comment)
                    Text(step.exercise.isTimed ? "⏱ \(step.exercise.workDisplayValue)s" : "× \(step.exercise.reps) reps")
                        .terminalFont(11)
                        .foregroundColor(isCompleted ? theme.comment.opacity(0.3) : theme.comment)
                    if step.exercise.perSide {
                        Text("↔")
                            .terminalFont(11)
                            .foregroundColor(isCompleted ? theme.orange.opacity(0.3) : theme.orange)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(isCurrent ? theme.card : Color.clear)
    }
}
