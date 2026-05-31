import SwiftUI

struct ExerciseCardView: View {
    let step: WorkoutStep
    let totalSteps: Int
    let currentIndex: Int
    let estimatedMinutes: Int
    @Binding var selectedRating: SetRating
    let onComplete: () -> Void
    let onQuit: () -> Void
    let onShowOverview: () -> Void

    @Environment(\.theme) private var theme
    @State private var dragOffset: CGFloat = 0

    private let swipeThreshold: CGFloat = 80

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Full-screen swipe area
                Color.clear
                    .contentShape(Rectangle())

                VStack(spacing: 0) {
                    // Top bar
                    HStack {
                        Button {
                            onQuit()
                        } label: {
                            Text("[ ✕ ]")
                                .terminalFont(14, weight: .bold)
                                .foregroundColor(theme.comment)
                        }

                        Spacer()

                        Text("~\(estimatedMinutes) min left")
                            .terminalFont(12)
                            .foregroundColor(theme.comment)

                        Spacer()

                        HStack(spacing: 12) {
                            Button {
                                onShowOverview()
                            } label: {
                                Image(systemName: "list.bullet")
                                    .foregroundColor(theme.comment)
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                            }

                            Text("\(currentIndex + 1)/\(totalSteps)")
                                .terminalFont(13)
                                .foregroundColor(theme.comment)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(theme.darkCard)
                                .frame(height: 3)
                            Rectangle()
                                .fill(theme.blue)
                                .frame(width: geo.size.width * Double(currentIndex) / Double(max(totalSteps, 1)), height: 3)
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Spacer()

                    // Section label
                    if step.isFirstInSection {
                        Text("// \(step.sectionName.uppercased())")
                            .terminalFont(13)
                            .foregroundColor(theme.purple)
                            .padding(.bottom, 8)
                    }

                    // Exercise card
                    VStack(spacing: 16) {
                        Text(step.exercise.name.uppercased())
                            .terminalFont(22, weight: .bold)
                            .foregroundColor(theme.fg)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 24) {
                            VStack(spacing: 4) {
                                Text("SET")
                                    .terminalFont(11)
                                    .foregroundColor(theme.comment)
                                Text("\(step.setNumber) of \(step.exercise.sets)")
                                    .terminalFont(18, weight: .bold)
                                    .foregroundColor(theme.blue)
                            }

                            Rectangle()
                                .fill(theme.comment.opacity(0.3))
                                .frame(width: 1, height: 30)

                            VStack(spacing: 4) {
                                Text("REPS")
                                    .terminalFont(11)
                                    .foregroundColor(theme.comment)
                                Text("\(step.exercise.reps)")
                                    .terminalFont(18, weight: .bold)
                                    .foregroundColor(theme.green)
                            }
                        }

                        if step.exercise.perSide {
                            Text("↔ EACH SIDE")
                                .terminalFont(12, weight: .bold)
                                .foregroundColor(theme.orange)
                        }

                        if !step.exercise.notes.isEmpty {
                            Divider()
                                .background(theme.comment.opacity(0.3))
                            Text(step.exercise.notes)
                                .terminalFont(13)
                                .foregroundColor(theme.comment)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(24)
                    .terminalCard()
                    .padding(.horizontal, 20)
                    .offset(x: dragOffset)

                    Spacer()

                    // Rating buttons
                    VStack(spacing: 12) {
                        Text("rate this set")
                            .terminalFont(12)
                            .foregroundColor(theme.comment)

                        HStack(spacing: 12) {
                            ForEach(SetRating.allCases, id: \.self) { rating in
                                Button {
                                    selectedRating = rating
                                } label: {
                                    Text("[ \(rating.emoji) \(rating.label) ]")
                                }
                                .buttonStyle(TerminalButtonStyle(
                                    color: ratingColor(rating)
                                ))
                                .opacity(selectedRating == rating ? 1.0 : 0.4)
                            }
                        }
                    }
                    .padding(.bottom, 8)

                    // Swipe hint
                    HStack(spacing: 4) {
                        Text("← swipe left to complete")
                            .terminalFont(12)
                            .foregroundColor(theme.comment.opacity(0.5))
                    }
                    .padding(.bottom, 16)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 20, coordinateSpace: .global)
                    .onChanged { value in
                        if value.translation.width < 0 {
                            dragOffset = value.translation.width
                        }
                    }
                    .onEnded { value in
                        if value.translation.width < -swipeThreshold {
                            withAnimation(.easeOut(duration: 0.2)) {
                                dragOffset = -(proxy.size.width + 80)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                dragOffset = 0
                                onComplete()
                            }
                        } else {
                            withAnimation(.spring(response: 0.3)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
        }
    }

    private func ratingColor(_ rating: SetRating) -> Color {
        switch rating {
        case .couldNotComplete: return theme.red
        case .good: return theme.green
        case .tooEasy: return theme.yellow
        }
    }
}
