import SwiftUI
import SwiftData
import UIKit

struct HealthSyncView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Run.startDate, order: .reverse) private var workouts: [Run]

    let settings: AppSettings
    let coordinator: SyncCoordinator

    @State private var workingDate: Date
    @State private var requesting = false
    @State private var errorText: String?

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
                        SectionHeader(text: "SUMMARY")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(summaryText)
                                .terminalFont(13, weight: .bold)
                                .foregroundColor(theme.fg)
                            syncStateText
                        }
                        .terminalCard()

                        SectionHeader(text: "APPLE HEALTH")
                        VStack(alignment: .leading, spacing: 12) {
                            Text(settings.hasOnboarded ? "Health access has been requested." : "Connect Apple Health to discover runs and rides.")
                                .terminalFont(13)
                                .foregroundColor(theme.fg)
                            Text("Read-only. Flow never writes workouts back.")
                                .terminalFont(12)
                                .foregroundColor(theme.comment)

                            if settings.hasOnboarded {
                                Button("[ sync now ]") {
                                    Task { await sync() }
                                }
                                .buttonStyle(TerminalButtonStyle(color: theme.green))
                                .disabled(requesting)
                            } else {
                                Button(requesting ? "[ requesting... ]" : "[ connect apple health ]") {
                                    begin()
                                }
                                .buttonStyle(TerminalButtonStyle(color: theme.cyan))
                                .disabled(requesting)
                            }

                            if let errorText {
                                Text("[error] \(errorText)")
                                    .terminalFont(12)
                                    .foregroundColor(theme.red)
                            }

                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                Link("[ open ios settings ]", destination: url)
                                    .terminalFont(12, weight: .bold)
                                    .foregroundColor(theme.yellow)
                            }
                        }
                        .terminalCard()

                        SectionHeader(text: "SEARCH FROM")
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Look for workouts from...")
                                .terminalFont(13)
                                .foregroundColor(theme.fg)
                            DatePicker("", selection: $workingDate, displayedComponents: [.date])
                                .datePickerStyle(.compact)
                                .labelsHidden()
                                .colorScheme(.dark)
                                .accentColor(theme.cyan)
                            Text("// moving this earlier backfills older Health workouts")
                                .terminalFont(11)
                                .foregroundColor(theme.comment)
                        }
                        .terminalCard()

                        Button("[ apply date & sync ]") {
                            Task { await sync() }
                        }
                        .buttonStyle(TerminalButtonStyle(color: theme.cyan))
                        .disabled(requesting || !settings.hasOnboarded)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("health sync")
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

    @ViewBuilder private var syncStateText: some View {
        switch coordinator.state {
        case .idle:
            Text(coordinator.lastSyncedAt.map { "last sync \($0.formatted(.dateTime.day().month(.abbreviated).hour().minute()))" } ?? "not synced yet")
                .terminalFont(12)
                .foregroundColor(theme.comment)
        case .syncing:
            Text("// syncing...")
                .terminalFont(12)
                .foregroundColor(theme.comment)
        case .error(let message):
            Text("[error] \(message)")
                .terminalFont(12)
                .foregroundColor(theme.red)
        }
    }

    private var summaryText: String {
        let visible = workouts.filter { $0.startDate >= settings.startDate }
        let runCount = visible.filter { $0.activity == .running }.count
        let rideCount = visible.filter { $0.activity == .cycling }.count
        return "\(runCount) runs | \(rideCount) rides found"
    }

    private func begin() {
        requesting = true
        errorText = nil
        Task {
            do {
                try await HealthKitService.shared.requestAuthorization()
                await MainActor.run {
                    settings.hasOnboarded = true
                }
                await sync()
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    requesting = false
                }
            }
        }
    }

    private func sync() async {
        await MainActor.run {
            settings.startDate = workingDate
            requesting = true
            errorText = nil
        }
        await coordinator.sync(startDate: workingDate)
        await MainActor.run { requesting = false }
    }
}
