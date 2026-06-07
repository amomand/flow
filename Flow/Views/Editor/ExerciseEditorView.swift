import SwiftUI

struct ExerciseEditorView: View {
    @State private var exercise: ExerciseBlock
    @State private var isNew: Bool
    let onSave: (ExerciseBlock) -> Void
    @Environment(\.dismiss) private var dismiss

    init(exercise: ExerciseBlock?, onSave: @escaping (ExerciseBlock) -> Void) {
        if let exercise {
            self._exercise = State(initialValue: exercise)
            self._isNew = State(initialValue: false)
        } else {
            self._exercise = State(initialValue: ExerciseBlock(name: ""))
            self._isNew = State(initialValue: true)
        }
        self.onSave = onSave
    }

    var body: some View {
        ZStack {
            TN.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    editorField("NAME", text: $exercise.name)

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SETS")
                                .terminalFont(11)
                                .foregroundColor(TN.comment)
                            HStack(spacing: 12) {
                                Button {
                                    if exercise.sets > 1 { exercise.sets -= 1 }
                                } label: {
                                    Text("−")
                                        .terminalFont(18, weight: .bold)
                                        .foregroundColor(TN.red)
                                        .frame(width: 36, height: 36)
                                        .background(TN.darkCard)
                                        .cornerRadius(4)
                                }
                                Text("\(exercise.sets)")
                                    .terminalFont(22, weight: .bold)
                                    .foregroundColor(TN.fg)
                                    .frame(minWidth: 30)
                                Button {
                                    exercise.sets += 1
                                } label: {
                                    Text("+")
                                        .terminalFont(18, weight: .bold)
                                        .foregroundColor(TN.green)
                                        .frame(width: 36, height: 36)
                                        .background(TN.darkCard)
                                        .cornerRadius(4)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(exercise.isTimed ? "TIME (SEC)" : "REPS")
                                .terminalFont(11)
                                .foregroundColor(TN.comment)
                            HStack(spacing: 12) {
                                Button {
                                    decrementWorkValue()
                                } label: {
                                    Text("−")
                                        .terminalFont(18, weight: .bold)
                                        .foregroundColor(TN.red)
                                        .frame(width: 36, height: 36)
                                        .background(TN.darkCard)
                                        .cornerRadius(4)
                                }
                                Text("\(exercise.workDisplayValue)")
                                    .terminalFont(22, weight: .bold)
                                    .foregroundColor(TN.fg)
                                    .frame(minWidth: 30)
                                Button {
                                    incrementWorkValue()
                                } label: {
                                    Text("+")
                                        .terminalFont(18, weight: .bold)
                                        .foregroundColor(TN.green)
                                        .frame(width: 36, height: 36)
                                        .background(TN.darkCard)
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }

                    Toggle(isOn: timedBinding) {
                        Text("Timed exercise")
                            .terminalFont(14)
                            .foregroundColor(TN.fg)
                    }
                    .tint(TN.blue)

                    // Rest between sets
                    VStack(alignment: .leading, spacing: 4) {
                        Text("REST BETWEEN SETS (SEC)")
                            .terminalFont(11)
                            .foregroundColor(TN.comment)

                        HStack(spacing: 8) {
                            ForEach([0, 15, 30, 45, 60, 90, 120], id: \.self) { sec in
                                Button {
                                    exercise.restBetweenSetsSeconds = sec
                                } label: {
                                    Text(sec == 0 ? "—" : "\(sec)")
                                        .terminalFont(13, weight: .bold)
                                        .foregroundColor(exercise.restBetweenSetsSeconds == sec ? TN.bg : TN.fg)
                                        .frame(minWidth: 36, minHeight: 36)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(exercise.restBetweenSetsSeconds == sec ? TN.blue : TN.darkCard)
                                        )
                                }
                            }
                        }
                    }

                    // Rest after exercise
                    VStack(alignment: .leading, spacing: 4) {
                        Text("REST AFTER EXERCISE (SEC)")
                            .terminalFont(11)
                            .foregroundColor(TN.comment)

                        HStack(spacing: 8) {
                            ForEach([0, 15, 30, 45, 60, 90, 120], id: \.self) { sec in
                                Button {
                                    exercise.restAfterExerciseSeconds = sec
                                } label: {
                                    Text(sec == 0 ? "—" : "\(sec)")
                                        .terminalFont(13, weight: .bold)
                                        .foregroundColor(exercise.restAfterExerciseSeconds == sec ? TN.bg : TN.fg)
                                        .frame(minWidth: 36, minHeight: 36)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(exercise.restAfterExerciseSeconds == sec ? TN.blue : TN.darkCard)
                                        )
                                }
                            }
                        }
                    }

                    // Per side toggle
                    Toggle(isOn: $exercise.perSide) {
                        Text("Each side")
                            .terminalFont(14)
                            .foregroundColor(TN.fg)
                    }
                    .tint(TN.blue)

                    // Phase variants (Peak / Deload overrides)
                    PhaseVariantsSection(exercise: $exercise)

                    // Notes
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NOTES")
                            .terminalFont(11)
                            .foregroundColor(TN.comment)
                        TextField("Optional notes...", text: $exercise.notes, axis: .vertical)
                            .terminalFont(14)
                            .foregroundColor(TN.fg)
                            .textFieldStyle(.plain)
                            .lineLimit(3...6)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(TN.darkCard)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(TN.comment.opacity(0.3), lineWidth: 1)
                                    )
                            )
                    }
                }
                .padding()
            }
        }
        .navigationTitle(isNew ? "New Exercise" : "Edit Exercise")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TN.bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .foregroundColor(TN.comment)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(exercise)
                    dismiss()
                }
                .foregroundColor(TN.blue)
                .bold()
                .disabled(exercise.name.isEmpty)
            }
        }
    }

    private func editorField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .terminalFont(11)
                .foregroundColor(TN.comment)
            TextField("", text: text)
                .terminalFont(16, weight: .bold)
                .foregroundColor(TN.fg)
                .textFieldStyle(.plain)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(TN.darkCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(TN.comment.opacity(0.3), lineWidth: 1)
                        )
                )
        }
    }

    private var timedBinding: Binding<Bool> {
        Binding(
            get: { exercise.isTimed },
            set: { isTimed in
                if isTimed {
                    exercise.durationSeconds = exercise.durationSeconds ?? max(exercise.reps, 30)
                } else {
                    exercise.durationSeconds = nil
                }
            }
        )
    }

    private func decrementWorkValue() {
        if exercise.isTimed {
            let currentDuration = exercise.durationSeconds ?? max(exercise.reps, 30)
            exercise.durationSeconds = max(5, currentDuration - 5)
        } else if exercise.reps > 1 {
            exercise.reps -= 1
        }
    }

    private func incrementWorkValue() {
        if exercise.isTimed {
            let currentDuration = exercise.durationSeconds ?? max(exercise.reps, 30)
            exercise.durationSeconds = currentDuration + 5
        } else {
            exercise.reps += 1
        }
    }
}

// MARK: - Phase Variants

struct PhaseVariantsSection: View {
    @Binding var exercise: ExerciseBlock
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text("PHASE VARIANTS")
                        .terminalFont(11, weight: .bold)
                        .foregroundColor(TN.comment)
                    Text(summaryText)
                        .terminalFont(11)
                        .foregroundColor(TN.comment.opacity(0.7))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(TN.comment)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                PhaseOverrideEditor(phase: .peak, exercise: $exercise)
                PhaseOverrideEditor(phase: .deload, exercise: $exercise)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(TN.darkCard.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(TN.comment.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private var summaryText: String {
        let active = [WorkoutPhase.peak, .deload].filter { !(exercise.phaseOverrides[$0]?.isEmpty ?? true) }
        if active.isEmpty { return "same as base" }
        return active.map(\.displayName).joined(separator: " · ")
    }
}

struct PhaseOverrideEditor: View {
    let phase: WorkoutPhase
    @Binding var exercise: ExerciseBlock

    private var override: PhaseOverride {
        exercise.phaseOverrides[phase] ?? PhaseOverride()
    }

    private func update(_ mutate: (inout PhaseOverride) -> Void) {
        var o = override
        mutate(&o)
        if o.isEmpty {
            exercise.phaseOverrides.removeValue(forKey: phase)
        } else {
            exercise.phaseOverrides[phase] = o
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(phase.displayName.uppercased())
                    .terminalFont(11, weight: .bold)
                    .foregroundColor(TN.bg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 3).fill(phase.accentColor)
                    )
                Spacer()
                if !override.isEmpty {
                    Button {
                        exercise.phaseOverrides.removeValue(forKey: phase)
                    } label: {
                        Text("[ RESET ]")
                            .terminalFont(10, weight: .bold)
                            .foregroundColor(TN.comment)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 16) {
                overrideStepper(
                    label: "SETS",
                    value: override.sets,
                    baseValue: exercise.sets,
                    minValue: 1,
                    step: 1,
                    onChange: { newValue in update { $0.sets = newValue } }
                )
                overrideStepper(
                    label: exercise.isTimed ? "TIME" : "REPS",
                    value: exercise.isTimed ? override.durationSeconds : override.reps,
                    baseValue: exercise.workDisplayValue,
                    minValue: exercise.isTimed ? 5 : 1,
                    step: exercise.isTimed ? 5 : 1,
                    onChange: { newValue in
                        update {
                            if exercise.isTimed {
                                $0.durationSeconds = newValue
                            } else {
                                $0.reps = newValue
                            }
                        }
                    }
                )
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func overrideStepper(
        label: String,
        value: Int?,
        baseValue: Int,
        minValue: Int,
        step: Int,
        onChange: @escaping (Int?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .terminalFont(10)
                .foregroundColor(TN.comment)
            HStack(spacing: 8) {
                Button {
                    let current = value ?? baseValue
                    let next = max(minValue, current - step)
                    onChange(next == baseValue ? nil : next)
                } label: {
                    Text("−")
                        .terminalFont(14, weight: .bold)
                        .foregroundColor(TN.red)
                        .frame(width: 28, height: 28)
                        .background(TN.darkCard)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Text(value.map(String.init) ?? "— \(baseValue)")
                    .terminalFont(14, weight: value == nil ? .regular : .bold)
                    .foregroundColor(value == nil ? TN.comment : TN.fg)
                    .frame(minWidth: 44)

                Button {
                    let current = value ?? baseValue
                    let next = current + step
                    onChange(next == baseValue ? nil : next)
                } label: {
                    Text("+")
                        .terminalFont(14, weight: .bold)
                        .foregroundColor(TN.green)
                        .frame(width: 28, height: 28)
                        .background(TN.darkCard)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
