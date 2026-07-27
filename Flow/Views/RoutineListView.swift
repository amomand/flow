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
    /// Reordering is a mode rather than a long-press, because long-press is
    /// already the routine card's context menu and a card holds its own
    /// buttons. A mode also gives the list somewhere to put drag handles.
    @State private var isReordering = false

    var body: some View {
        NavigationStack {
            ZStack {
                TN.bg.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    FlowScreenHeader(
                        title: "STRENGTH",
                        subtitle: isReordering ? "drag to reorder" : "select routine to begin"
                    ) {
                        HStack(spacing: 8) {
                            if isReordering {
                                Button {
                                    isReordering = false
                                } label: {
                                    HeaderIcon(systemName: "checkmark", color: TN.green)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Done reordering")
                            } else {
                                Button {
                                    showingNewRoutine = true
                                } label: {
                                    HeaderIcon(systemName: "plus", color: TN.green)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("New routine")
                            }

                            Menu {
                                // Reordering needs two routines to mean
                                // anything, and the mode has no exit worth
                                // entering for one.
                                Button("Reorder Routines") {
                                    isReordering = true
                                }
                                .disabled(store.routines.count < 2)
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

                    // A List rather than a LazyVStack, so dragging a routine
                    // into place is the platform's own reorder rather than a
                    // hand-rolled gesture. That also brings VoiceOver's
                    // "Reorder" rotor for free, which is the accessible
                    // alternative to dragging. The chrome is stripped back so
                    // the terminal cards look exactly as they did.
                    List {
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
                                    // Reordering is a whole-list mode, so a tap
                                    // is a grab at the row rather than a
                                    // request to start a workout.
                                    guard !isReordering, routine.canStartWorkout else { return }
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
                                // After the tap and the context menu, so
                                // reordering suppresses both. The row's own
                                // drag chrome belongs to the List, not to this
                                // content, so dragging still works.
                                .allowsHitTesting(!isReordering)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                        .onMove { offsets, destination in
                            store.moveRoutines(fromOffsets: offsets, toOffset: destination)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, .constant(isReordering ? .active : .inactive))
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

/// Icon hard against its text.
///
/// A `List` row gives its labels row-wide icon alignment, which pushes each
/// icon away from its own text and wraps the stats line over two. The card
/// wants the three stats reading as three tight pairs, the way they did before
/// the list became a `List`.
private struct StatLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
        .fixedSize(horizontal: false, vertical: true)
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
            .labelStyle(StatLabelStyle())
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
