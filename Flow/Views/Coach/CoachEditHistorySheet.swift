import SwiftUI

/// Audit trail of applied coach patches, with rollback.
///
/// Each entry can restore the routine sections recorded before that edit
/// applied. When the routine has changed since the edit, the first tap
/// surfaces the overwrite warning and a second explicit tap is required.
struct CoachEditHistorySheet: View {
    let store: RoutineStore

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var confirmingOverwriteId: UUID?

    var body: some View {
        ZStack {
            TN.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                header

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

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let records = store.editHistory?.newestFirst, !records.isEmpty {
                            ForEach(records) { record in
                                recordRow(record)
                            }
                        } else {
                            Text("No coach edits have been applied yet. Applied patches appear here and can be rolled back.")
                                .terminalFont(12)
                                .foregroundColor(TN.comment)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            .padding()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack {
            Text("// COACH EDIT HISTORY")
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

    private func recordRow(_ record: CoachEditRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                outcomeChip(record)
                Text(record.routineName)
                    .terminalFont(12, weight: .bold)
                    .foregroundColor(TN.fg)
                Spacer()
                Text(record.appliedAt.formatted(date: .abbreviated, time: .shortened))
                    .terminalFont(11)
                    .foregroundColor(TN.comment)
            }

            if !record.rationale.isEmpty {
                Text(record.rationale)
                    .terminalFont(12)
                    .foregroundColor(TN.comment)
            }

            ForEach(record.diffs.prefix(3)) { diff in
                Text("\(diff.operationIndex). \(diff.title): \(diff.before) -> \(diff.after)")
                    .terminalFont(11)
                    .foregroundColor(TN.blue)
            }
            if record.diffs.count > 3 {
                Text("+ \(record.diffs.count - 3) more operation\(record.diffs.count - 3 == 1 ? "" : "s")")
                    .terminalFont(11)
                    .foregroundColor(TN.comment)
            }

            if let provenanceLine = provenanceLine(for: record) {
                Text(provenanceLine)
                    .terminalFont(11)
                    .foregroundColor(TN.comment)
            }

            if record.outcome == .applied {
                if confirmingOverwriteId == record.id {
                    Text("This routine changed after the edit was applied. Restoring will overwrite those later changes.")
                        .terminalFont(11)
                        .foregroundColor(TN.yellow)
                    Button {
                        restore(record, allowingOverwrite: true)
                    } label: {
                        Text("[ RESTORE ANYWAY ]")
                    }
                    .buttonStyle(TerminalButtonStyle(color: TN.red))
                } else {
                    Button {
                        restore(record, allowingOverwrite: false)
                    } label: {
                        Text("[ RESTORE ]")
                    }
                    .buttonStyle(TerminalButtonStyle(color: TN.yellow))
                }
            } else if let restoredAt = record.restoredAt {
                Text("Restored \(restoredAt.formatted(date: .abbreviated, time: .shortened))")
                    .terminalFont(11)
                    .foregroundColor(TN.comment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .terminalCard()
    }

    private func outcomeChip(_ record: CoachEditRecord) -> some View {
        let (label, color): (String, Color) = {
            switch record.outcome {
            case .applied:
                return (record.wasRebased ? "APPLIED · REBASED" : "APPLIED", TN.green)
            case .restored:
                return ("RESTORED", TN.comment)
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

    private func provenanceLine(for record: CoachEditRecord) -> String? {
        guard let provenance = record.provenance else { return nil }
        var parts: [String] = []
        switch provenance.source {
        case .paste: parts.append("pasted")
        case .file: parts.append("file import")
        case .deepLink: parts.append("deep link")
        case .bridge: parts.append("bridge")
        case nil: break
        }
        if let provider = provenance.assistantProvider {
            parts.append(provider)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func restore(_ record: CoachEditRecord, allowingOverwrite: Bool) {
        errorMessage = nil
        statusMessage = nil
        switch store.restoreCoachEdit(record, allowingOverwrite: allowingOverwrite) {
        case .success(let routine):
            confirmingOverwriteId = nil
            statusMessage = "Restored \(routine.name) to its pre-edit exercises."
        case .failure(.routineChangedSinceEdit):
            // Surface the warning inline on this entry; the next tap must be
            // the explicit overwrite.
            confirmingOverwriteId = record.id
        case .failure(let error):
            confirmingOverwriteId = nil
            errorMessage = error.localizedDescription
        }
    }
}
