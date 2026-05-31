import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let settings: AppSettings
    let coordinator: SyncCoordinator

    @State private var workingDate: Date

    init(settings: AppSettings, coordinator: SyncCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
        _workingDate = State(initialValue: settings.startDate)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SectionHeader(text: "START DATE")
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Show me runs from…")
                                .terminalFont(13)
                                .foregroundColor(theme.fg)
                            DatePicker("", selection: $workingDate, displayedComponents: [.date])
                                .datePickerStyle(.compact)
                                .labelsHidden()
                                .colorScheme(.dark)
                                .accentColor(theme.cyan)
                            Text("// changing this refilters the list. no data is deleted.")
                                .terminalFont(11)
                                .foregroundColor(theme.comment)
                        }
                        .terminalCard()

                        Button("[ apply & re-sync ]") {
                            settings.startDate = workingDate
                            Task { await coordinator.sync(startDate: workingDate) }
                            dismiss()
                        }
                        .buttonStyle(TerminalButtonStyle(color: theme.cyan))

                        SectionHeader(text: "PERMISSIONS")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("If runs are missing, check Health permissions.")
                                .terminalFont(12)
                                .foregroundColor(theme.fg)
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                Link("[ open settings ]", destination: url)
                                    .terminalFont(12, weight: .bold)
                                    .foregroundColor(theme.yellow)
                            }
                        }
                        .terminalCard()

                        SectionHeader(text: "SYNC")
                        Button("[ re-sync now ]") {
                            Task { await coordinator.sync(startDate: settings.startDate) }
                        }
                        .buttonStyle(TerminalButtonStyle(color: theme.green))
                    }
                    .padding(16)
                }
            }
            .navigationTitle("settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("[ done ]") { dismiss() }
                        .terminalFont(12, weight: .bold)
                        .foregroundColor(theme.cyan)
                }
            }
            .toolbarBackground(theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
