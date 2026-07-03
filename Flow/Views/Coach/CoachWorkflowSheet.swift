import SwiftUI
import UniformTypeIdentifiers

struct CoachWorkflowSheet: View {
    let store: RoutineStore
    let historyStore: StrengthHistoryStore
    let runs: [Run]
    let inbox: CoachPatchInbox

    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var selectedPatchId: UUID?
    @State private var preview: FlowRoutinePatchPreview?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var showingImporter = false
    @State private var shareFile: ShareFile?

    var body: some View {
        ZStack {
            TN.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        contextSection
                        inboxSection
                        previewSection
                        resolvedSection
                    }
                    .padding(.bottom, 12)
                }

                actionBar
            }
            .padding()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { autoSelectIfNeeded() }
        .onChange(of: inbox.pending.map(\.id)) { _, _ in autoSelectIfNeeded() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            clearMessages()
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if case .added(let patch) = inbox.ingestFile(at: url) {
                    select(patch)
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $shareFile) { file in
            ActivityShareSheet(url: file.url)
        }
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

            HStack(spacing: 10) {
                Button {
                    copyCoachContext()
                } label: {
                    Text("[ COPY ]")
                }
                .buttonStyle(TerminalButtonStyle(color: TN.blue))

                Button {
                    shareCoachContextFile()
                } label: {
                    Text("[ SHARE FILE ]")
                }
                .buttonStyle(TerminalButtonStyle(color: TN.blue))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PENDING PATCHES\(inbox.pending.isEmpty ? "" : " (\(inbox.pending.count))")")
                .terminalFont(13, weight: .bold)
                .foregroundColor(TN.green)

            HStack(spacing: 10) {
                Button {
                    pastePatch()
                } label: {
                    Text("[ PASTE PATCH ]")
                }
                .buttonStyle(TerminalButtonStyle(color: TN.blue))

                Button {
                    showingImporter = true
                } label: {
                    Text("[ IMPORT FILE ]")
                }
                .buttonStyle(TerminalButtonStyle(color: TN.blue))
            }

            if let notice = inbox.notice {
                Text(notice)
                    .terminalFont(12)
                    .foregroundColor(TN.yellow)
            }

            if inbox.pending.isEmpty {
                Text("No pending patches. Paste one, import a JSON file, or open a flow://coach/patch link.")
                    .terminalFont(12)
                    .foregroundColor(TN.comment)
            } else {
                ForEach(inbox.pending) { patch in
                    pendingRow(patch)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pendingRow(_ patch: PendingCoachPatch) -> some View {
        let summary = inbox.summary(for: patch, routines: store.routines)
        let isSelected = patch.id == selectedPatchId
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                readinessChip(summary.readiness)
                Text(summary.routineName ?? "Unknown routine")
                    .terminalFont(12, weight: .bold)
                    .foregroundColor(TN.fg)
                Spacer()
                Button {
                    removePatch(patch)
                } label: {
                    Text("[ x ]")
                        .terminalFont(12)
                        .foregroundColor(TN.comment)
                }
                .buttonStyle(.plain)
            }
            Text(sourceLine(for: patch, operationCount: summary.operationCount))
                .terminalFont(11)
                .foregroundColor(TN.comment)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(TN.darkCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? TN.green.opacity(0.7) : TN.comment.opacity(0.3), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            select(patch)
        }
    }

    private func readinessChip(_ readiness: PendingCoachPatchSummary.Readiness) -> some View {
        let (label, color): (String, Color) = {
            switch readiness {
            case .ready: return ("READY", TN.green)
            case .rebase: return ("REBASE", TN.yellow)
            case .conflict: return ("CONFLICT", TN.red)
            case .invalid: return ("INVALID", TN.red)
            }
        }()
        return Text(label)
            .terminalFont(10, weight: .bold)
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color.opacity(0.6), lineWidth: 1)
            )
    }

    private func sourceLine(for patch: PendingCoachPatch, operationCount: Int) -> String {
        var parts: [String] = []
        switch patch.source {
        case .paste: parts.append("pasted")
        case .file: parts.append("file import")
        case .deepLink: parts.append("deep link")
        case .bridge: parts.append("bridge")
        }
        if let provider = patch.assistantProvider {
            parts.append(provider)
        }
        parts.append(patch.receivedAt.formatted(date: .abbreviated, time: .shortened))
        if operationCount > 0 {
            parts.append("\(operationCount) op\(operationCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
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
                if preview.rebasedFromHash != nil {
                    Text("REBASED: the routine changed after this patch was written, but every edit still matches the current values. Review the diff before applying.")
                        .terminalFont(12)
                        .foregroundColor(TN.yellow)
                }

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

    @ViewBuilder
    private var resolvedSection: some View {
        if !inbox.resolved.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("RESOLVED (\(inbox.resolved.count))")
                        .terminalFont(13, weight: .bold)
                        .foregroundColor(TN.comment)
                    Spacer()
                    Button {
                        inbox.clearResolved()
                    } label: {
                        Text("[ CLEAR ]")
                            .terminalFont(12)
                            .foregroundColor(TN.comment)
                    }
                }

                ForEach(inbox.resolved.prefix(5)) { patch in
                    HStack {
                        Text(patch.status == .applied ? "APPLIED" : "REJECTED")
                            .terminalFont(10, weight: .bold)
                            .foregroundColor(patch.status == .applied ? TN.green.opacity(0.6) : TN.comment)
                        Text((patch.resolvedAt ?? patch.receivedAt).formatted(date: .abbreviated, time: .shortened))
                            .terminalFont(11)
                            .foregroundColor(TN.comment)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                applySelectedPatch()
            } label: {
                Text("[ APPLY PATCH ]")
            }
            .buttonStyle(TerminalButtonStyle(color: TN.green))
            .disabled(preview == nil)
            .opacity(preview == nil ? 0.45 : 1)

            Button {
                rejectSelectedPatch()
            } label: {
                Text("[ REJECT ]")
            }
            .buttonStyle(TerminalButtonStyle(color: TN.red))
            .disabled(selectedPatchId == nil)
            .opacity(selectedPatchId == nil ? 0.45 : 1)

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

    private var editorBackground: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(TN.darkCard)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(TN.comment.opacity(0.3), lineWidth: 1)
            )
    }

    // MARK: - Actions

    private func copyCoachContext() {
        clearMessages()
        guard let json = coachContextJSON() else {
            errorMessage = "Could not encode coach context."
            return
        }
        UIPasteboard.general.string = json
        statusMessage = "Coach context copied."
    }

    private func shareCoachContextFile() {
        clearMessages()
        guard let json = coachContextJSON() else {
            errorMessage = "Could not encode coach context."
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let name = "flow-coach-context-\(formatter.string(from: Date())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try Data(json.utf8).write(to: url, options: .atomic)
            shareFile = ShareFile(url: url)
        } catch {
            errorMessage = "Could not write coach context file: \(error.localizedDescription)"
        }
    }

    private func coachContextJSON() -> String? {
        store.exportCoachContextJSON(
            strengthWorkouts: historyStore.workouts,
            cardioWorkouts: runs,
            constraintsNotes: notes
        )
    }

    private func pastePatch() {
        clearMessages()
        guard let text = UIPasteboard.general.string else {
            errorMessage = "Clipboard does not contain text."
            return
        }
        switch inbox.enqueue(rawJSON: text, source: .paste) {
        case .added(let patch), .duplicate(let patch):
            select(patch)
        case .rejected(let reason):
            errorMessage = reason
        }
    }

    private func select(_ patch: PendingCoachPatch) {
        clearMessages()
        selectedPatchId = patch.id
        switch store.previewRoutinePatchJSON(patch.rawJSON) {
        case .success(let result):
            preview = result
            statusMessage = "Patch preview ready."
        case .failure(let error):
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func removePatch(_ patch: PendingCoachPatch) {
        inbox.remove(patch.id)
        if selectedPatchId == patch.id {
            clearSelection()
        }
    }

    private func applySelectedPatch() {
        clearMessages()
        guard let preview, let selectedPatchId else { return }
        switch store.applyRoutinePatchPreview(preview) {
        case .success(let routine):
            inbox.markApplied(selectedPatchId)
            clearSelection()
            statusMessage = "Applied patch to \(routine.name)."
        case .failure(let error):
            // The routine may have changed between preview and apply; the
            // stale preview must not stay on screen looking applicable.
            self.preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func rejectSelectedPatch() {
        clearMessages()
        guard let selectedPatchId else { return }
        inbox.markRejected(selectedPatchId)
        clearSelection()
        statusMessage = "Patch rejected."
    }

    private func restorePreviousRoutine() {
        clearMessages()
        if let routine = store.restoreLastCoachPatchBackup() {
            clearSelection()
            statusMessage = "Restored \(routine.name)."
        } else {
            errorMessage = "No previous coach patch state is available."
        }
    }

    private func autoSelectIfNeeded() {
        guard selectedPatchId == nil || !inbox.pending.contains(where: { $0.id == selectedPatchId }) else { return }
        guard let newest = inbox.pending.first else {
            clearSelection()
            return
        }
        select(newest)
    }

    private func clearSelection() {
        selectedPatchId = nil
        preview = nil
    }

    private func clearMessages() {
        errorMessage = nil
        statusMessage = nil
        inbox.notice = nil
    }
}

private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
