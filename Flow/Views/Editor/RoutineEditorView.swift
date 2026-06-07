import SwiftUI

struct RoutineEditorView: View {
    @Bindable var store: RoutineStore
    @State private var routine: Routine
    @State private var isNew: Bool
    @Environment(\.dismiss) private var dismiss

    init(store: RoutineStore, routine: Routine?) {
        self.store = store
        if let routine {
            self._routine = State(initialValue: routine)
            self._isNew = State(initialValue: false)
        } else {
            self._routine = State(initialValue: Routine(name: "New Routine"))
            self._isNew = State(initialValue: true)
        }
    }

    var body: some View {
        ZStack {
            TN.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Routine name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("// ROUTINE NAME")
                            .terminalFont(12)
                            .foregroundColor(TN.purple)
                        TextField("Routine name", text: $routine.name)
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
                    .padding(.horizontal)

                    // Sections
                    ForEach($routine.sections) { $section in
                        SectionEditorBlock(
                            section: $section,
                            onDelete: {
                                routine.sections.removeAll { $0.id == section.id }
                            }
                        )
                    }

                    // Add section
                    Button {
                        routine.sections.append(Section(name: "New Section"))
                    } label: {
                        Text("[ + ADD SECTION ]")
                    }
                    .buttonStyle(TerminalButtonStyle(color: TN.green))
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("Edit Routine")
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
                    if isNew {
                        store.addRoutine(routine)
                    } else {
                        store.updateRoutine(routine)
                    }
                    dismiss()
                }
                .foregroundColor(TN.blue)
                .bold()
            }
        }
    }
}

struct SectionEditorBlock: View {
    @Binding var section: Section
    let onDelete: () -> Void
    @State private var editingExercise: ExerciseBlock?
    @State private var showNewExercise = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("//")
                    .terminalFont(14)
                    .foregroundColor(TN.purple)
                TextField("Section name", text: $section.name)
                    .terminalFont(14, weight: .bold)
                    .foregroundColor(TN.purple)
                    .textFieldStyle(.plain)
                Spacer()
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(TN.red.opacity(0.7))
                        .font(.system(size: 14))
                }
            }
            .padding(.horizontal)

            ForEach($section.exercises) { $exercise in
                ExerciseEditorRow(exercise: exercise)
                    .onTapGesture {
                        editingExercise = exercise
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            section.exercises.removeAll { $0.id == exercise.id }
                        }
                    }
            }
            .onMove { from, to in
                section.exercises.move(fromOffsets: from, toOffset: to)
            }

            Button {
                showNewExercise = true
            } label: {
                Text("[ + exercise ]")
                    .terminalFont(12)
                    .foregroundColor(TN.comment)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .sheet(item: $editingExercise) { exercise in
            NavigationStack {
                ExerciseEditorView(exercise: exercise) { updated in
                    if let idx = section.exercises.firstIndex(where: { $0.id == updated.id }) {
                        section.exercises[idx] = updated
                    }
                }
            }
        }
        .sheet(isPresented: $showNewExercise) {
            NavigationStack {
                ExerciseEditorView(exercise: nil) { newExercise in
                    section.exercises.append(newExercise)
                }
            }
        }
    }
}

struct ExerciseEditorRow: View {
    let exercise: ExerciseBlock

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .terminalFont(14, weight: .bold)
                    .foregroundColor(TN.fg)
                HStack(spacing: 8) {
                    Text(exercise.isTimed ? "\(exercise.sets)×\(exercise.workDisplayValue)s" : "\(exercise.sets)×\(exercise.reps)")
                        .terminalFont(12)
                        .foregroundColor(TN.blue)
                    if exercise.restBetweenSetsSeconds > 0 {
                        Text("rest \(exercise.restBetweenSetsSeconds)s/\(exercise.restAfterExerciseSeconds)s")
                            .terminalFont(12)
                            .foregroundColor(TN.comment)
                    }
                    if exercise.perSide {
                        Text("↔ each side")
                            .terminalFont(12)
                            .foregroundColor(TN.orange)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundColor(TN.comment)
                .font(.system(size: 12))
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(TN.darkCard)
    }
}
