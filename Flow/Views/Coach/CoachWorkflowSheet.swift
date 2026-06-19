import SwiftUI

struct CoachWorkflowSheet: View {
    let store: RoutineStore
    let historyStore: StrengthHistoryStore
    let runs: [Run]

    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var patchJSON = ""
    @State private var preview: FlowRoutinePatchPreview?
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    var body: some View {
        ZStack {
            TN.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        contextSection
                        patchSection
                        previewSection
                    }
                    .padding(.bottom, 12)
                }

                actionBar
            }
            .padding()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack {
            Text("// FLOW COACH")
                .terminalFont(16, weight: .bold)
                .foregroundColor(TN.purple)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("[ x ]")
                    .terminalFont(14, weight: .bold)
                    .foregroundColor(TN.comment)
            }
        }
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("COACH CONTEXT")
                .terminalFont(13, weight: .bold)
                .foregroundColor(TN.blue)

            TextEditor(text: $notes)
                .terminalFont(12)
                .foregroundColor(TN.fg)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(editorBackground)
                .frame(minHeight: 74)

            Button {
                copyCoachContext()
            } label: {
                Text("[ COPY COACH CONTEXT ]")
            }
            .buttonStyle(TerminalButtonStyle(color: TN.blue))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var patchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ROUTINE PATCH")
                .terminalFont(13, weight: .bold)
                .foregroundColor(TN.green)

            HStack(spacing: 10) {
                Button {
                    if let text = UIPasteboard.general.string {
                        patchJSON = text
                        preview = nil
                        clearMessages()
                    }
                } label: {
                    Text("[ PASTE PATCH ]")
                }
                .buttonStyle(TerminalButtonStyle(color: TN.blue))

                Button {
                    previewPatch()
                } label: {
                    Text("[ PREVIEW ]")
                }
                .buttonStyle(TerminalButtonStyle(color: TN.green))
                .disabled(patchJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(patchJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }

            TextEditor(text: $patchJSON)
                .terminalFont(12)
                .foregroundColor(TN.fg)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(editorBackground)
                .frame(minHeight: 180)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var previewSection: some View {
        if let errorMessage {
            Text(errorMessage)
                .terminalFont(12)
                .foregroundColor(TN.red)
        }

        if let statusMessage {
            Text(statusMessage)
                .terminalFont(12, weight: .bold)
                .foregroundColor(TN.green)
        }

        if let preview {
            VStack(alignment: .leading, spacing: 10) {
                Text(preview.updatedRoutine.name)
                    .terminalFont(14, weight: .bold)
                    .foregroundColor(TN.fg)

                if !preview.patch.rationale.isEmpty {
                    Text(preview.patch.rationale)
                        .terminalFont(12)
                        .foregroundColor(TN.comment)
                }

                ForEach(preview.diffs) { diff in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(diff.operationIndex). \(diff.title)")
                            .terminalFont(12, weight: .bold)
                            .foregroundColor(TN.blue)
                        Text("- \(diff.before)")
                            .terminalFont(12)
                            .foregroundColor(TN.comment)
                        Text("+ \(diff.after)")
                            .terminalFont(12)
                            .foregroundColor(TN.green)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .terminalCard()
                }
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    applyPatch()
                } label: {
                    Text("[ APPLY PATCH ]")
                }
                .buttonStyle(TerminalButtonStyle(color: TN.green))
                .disabled(preview == nil)
                .opacity(preview == nil ? 0.45 : 1)

                Button {
                    restorePreviousRoutine()
                } label: {
                    Text("[ RESTORE PREVIOUS ]")
                }
                .buttonStyle(TerminalButtonStyle(color: TN.yellow))
                .disabled(store.lastCoachPatchBackup == nil)
                .opacity(store.lastCoachPatchBackup == nil ? 0.45 : 1)
            }
        }
    }

    private var editorBackground: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(TN.darkCard)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(TN.comment.opacity(0.3), lineWidth: 1)
            )
    }

    private func copyCoachContext() {
        clearMessages()
        guard let json = store.exportCoachContextJSON(
            strengthWorkouts: historyStore.workouts,
            cardioWorkouts: runs,
            constraintsNotes: notes
        ) else {
            errorMessage = "Could not encode coach context."
            return
        }
        UIPasteboard.general.string = json
        statusMessage = "Coach context copied."
    }

    private func previewPatch() {
        clearMessages()
        switch store.previewRoutinePatchJSON(patchJSON) {
        case .success(let result):
            preview = result
            statusMessage = "Patch preview ready."
        case .failure(let error):
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func applyPatch() {
        clearMessages()
        guard let preview else { return }
        switch store.applyRoutinePatchPreview(preview) {
        case .success(let routine):
            self.preview = nil
            patchJSON = ""
            statusMessage = "Applied patch to \(routine.name)."
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func restorePreviousRoutine() {
        clearMessages()
        if let routine = store.restoreLastCoachPatchBackup() {
            preview = nil
            statusMessage = "Restored \(routine.name)."
        } else {
            errorMessage = "No previous coach patch state is available."
        }
    }

    private func clearMessages() {
        errorMessage = nil
        statusMessage = nil
    }
}
