import SwiftUI

struct RoutineListView: View {
    @Bindable var store: RoutineStore
    let historyStore: StrengthHistoryStore
    let runs: [Run]
    let settings: AppSettings
    let coordinator: SyncCoordinator
    let coachInbox: CoachPatchInbox

    @State private var selectedRoutine: Routine?
    @State private var editingRoutine: Routine?
    @State private var showingNewRoutine = false
    @State private var showingImport = false
    @State private var showingHealthSync = false
    @State private var showingHistory = false
    @State private var exportedJSON: String?
    @State private var showExportCopied = false

    var body: some View {
        NavigationStack {
            ZStack {
                TN.bg.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    FlowScreenHeader(title: "STRENGTH", subtitle: "select routine to begin") {
                        HStack(spacing: 8) {
                            Button {
                                showingNewRoutine = true
                            } label: {
                                HeaderIcon(systemName: "plus", color: TN.green)
                            }
                            .buttonStyle(.plain)

                            Menu {
                                Button("Workout History") {
                                    showingHistory = true
                                }
                                Button("Flow Coach") {
                                    // Presented from the app root so the same
                                    // sheet serves deep links and file opens.
                                    coachInbox.presentCoach = true
                                }
                                Button("Health Sync") {
                                    showingHealthSync = true
                                }
                                Button("Import Routine") {
                                    showingImport = true
                                }
                            } label: {
                                HeaderIcon(systemName: "ellipsis", color: TN.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Divider()
                        .background(TN.comment.opacity(0.3))
                        .padding(.vertical, 12)

                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(store.routines) { routine in
                                RoutineRow(
                                    routine: routine,
                                    onSelectPhase: { phase in
                                        var updated = routine
                                        updated.currentPhase = phase
                                        store.updateRoutine(updated)
                                    }
                                )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        guard routine.canStartWorkout else { return }
                                        // Use the latest stored version so currentPhase is fresh.
                                        selectedRoutine = store.routines.first(where: { $0.id == routine.id }) ?? routine
                                    }
                                    .contextMenu {
                                        Button("Edit") {
                                            editingRoutine = routine
                                        }
                                        Button("Export JSON") {
                                            if let json = store.exportRoutineJSON(routine) {
                                                UIPasteboard.general.string = json
                                                showExportCopied = true
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                                    showExportCopied = false
                                                }
                                            }
                                        }
                                        Button("Delete", role: .destructive) {
                                            if let idx = store.routines.firstIndex(where: { $0.id == routine.id }) {
                                                store.deleteRoutine(at: IndexSet(integer: idx))
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationBarHidden(true)
            .fullScreenCover(item: $selectedRoutine) { routine in
                WorkoutFlowView(routine: routine, store: store, historyStore: historyStore) {
                    selectedRoutine = nil
                }
            }
            .sheet(item: $editingRoutine) { routine in
                NavigationStack {
                    RoutineEditorView(store: store, routine: routine)
                }
            }
            .sheet(isPresented: $showingNewRoutine) {
                NavigationStack {
                    RoutineEditorView(store: store, routine: nil)
                }
            }
            .sheet(isPresented: $showingImport) {
                ImportRoutineSheet(store: store)
            }
            .sheet(isPresented: $showingHealthSync) {
                HealthSyncView(settings: settings, coordinator: coordinator)
            }
            .sheet(isPresented: $showingHistory) {
                WorkoutHistoryView(historyStore: historyStore)
            }
            .overlay {
                if showExportCopied {
                    Text("[ ✓ JSON COPIED ]")
                        .terminalFont(14, weight: .bold)
                        .foregroundColor(TN.green)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(TN.card)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(TN.green.opacity(0.5), lineWidth: 1)
                                )
                        )
                        .transition(.opacity)
                        .animation(.easeInOut, value: showExportCopied)
                }
            }
        }
    }
}

private struct HeaderIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .frame(width: 36, height: 36)
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

struct RoutineRow: View {
    let routine: Routine
    let onSelectPhase: (WorkoutPhase) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(routine.name)
                .terminalFont(16, weight: .bold)
                .foregroundColor(TN.fg)

            HStack(spacing: 16) {
                let exerciseCount = routine.sections.flatMap(\.exercises).count
                let resolved = routine.sections
                    .flatMap(\.exercises)
                    .map { $0.resolved(for: routine.currentPhase) }
                let setCount = resolved.map(\.sets).reduce(0, +)
                Label("\(routine.sections.count) blocks", systemImage: "list.bullet")
                Label("\(exerciseCount) exercises", systemImage: "figure.strengthtraining.traditional")
                Label("\(setCount) sets", systemImage: "repeat")
            }
            .terminalFont(12)
            .foregroundColor(TN.comment)

            PhasePicker(current: routine.currentPhase, onSelect: onSelectPhase)

            if !routine.canStartWorkout {
                Text("// add at least one exercise before starting")
                    .terminalFont(12)
                    .foregroundColor(TN.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .terminalCard()
    }
}

struct PhasePicker: View {
    let current: WorkoutPhase
    let onSelect: (WorkoutPhase) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WorkoutPhase.allCases, id: \.self) { phase in
                Button {
                    if phase != current { onSelect(phase) }
                } label: {
                    Text(phase.displayName.uppercased())
                        .terminalFont(11, weight: .bold)
                        .foregroundColor(phase == current ? TN.bg : TN.comment)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(phase == current ? phase.accentColor : TN.darkCard)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension WorkoutPhase {
    /// Accent color used in pickers and phase indicators.
    /// Final phase-wide theming arrives in Phase 3.
    var accentColor: Color {
        switch self {
        case .base: return TN.blue
        case .peak: return TN.red
        case .deload: return TN.green
        }
    }
}

struct ImportRoutineSheet: View {
    let store: RoutineStore
    @Environment(\.dismiss) private var dismiss
    @State private var jsonText = ""
    @State private var errorMessage: String?
    @State private var importedName: String?

    var body: some View {
        ZStack {
            TN.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("// IMPORT ROUTINE")
                        .terminalFont(16, weight: .bold)
                        .foregroundColor(TN.purple)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text("[ ✕ ]")
                            .terminalFont(14, weight: .bold)
                            .foregroundColor(TN.comment)
                    }
                }

                Text("Paste routine JSON below, or paste from clipboard.")
                    .terminalFont(12)
                    .foregroundColor(TN.comment)

                Button {
                    if let clip = UIPasteboard.general.string {
                        jsonText = clip
                    }
                } label: {
                    Text("[ PASTE FROM CLIPBOARD ]")
                }
                .buttonStyle(TerminalButtonStyle(color: TN.blue))

                TextEditor(text: $jsonText)
                    .terminalFont(12)
                    .foregroundColor(TN.fg)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(TN.darkCard)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(TN.comment.opacity(0.3), lineWidth: 1)
                            )
                    )
                    .frame(minHeight: 200)

                if let error = errorMessage {
                    Text(error)
                        .terminalFont(12)
                        .foregroundColor(TN.red)
                }

                if let name = importedName {
                    Text("✅ Imported: \(name)")
                        .terminalFont(13, weight: .bold)
                        .foregroundColor(TN.green)
                }

                HStack {
                    Spacer()
                    Button {
                        errorMessage = nil
                        importedName = nil
                        let result = store.importRoutineFromJSON(jsonText)
                        switch result {
                        case .success(let routine):
                            importedName = routine.name
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                dismiss()
                            }
                        case .failure(let error):
                            errorMessage = error.localizedDescription
                        }
                    } label: {
                        Text("[ IMPORT ]")
                    }
                    .buttonStyle(TerminalButtonStyle(color: TN.green))
                    .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
