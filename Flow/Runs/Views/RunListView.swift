import SwiftUI
import SwiftData

struct RunListView: View {
    @Environment(\.theme) private var theme
    @Query(sort: \Run.startDate, order: .reverse) private var runs: [Run]

    let activity: CardioActivity
    let settings: AppSettings
    let coordinator: SyncCoordinator
    @State private var showHealthSync = false

    var body: some View {
        let displayedRuns = visibleRuns
        return NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    FlowScreenHeader(title: activity.headerTitle, subtitle: runsSubtitle(runCount: displayedRuns.count)) {
                        Button {
                            showHealthSync = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 17, weight: .bold, design: .monospaced))
                                .foregroundColor(theme.blue)
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(theme.darkCard)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(theme.comment.opacity(0.3), lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()
                        .background(theme.comment.opacity(0.3))
                        .padding(.vertical, 12)

                    if displayedRuns.isEmpty {
                        EmptyStateView(activity: activity, syncState: coordinator.state, onRetry: refresh)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(displayedRuns) { run in
                                    NavigationLink {
                                        RunDetailView(run: run)
                                    } label: {
                                        RunRowView(run: run)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                        .refreshable { await coordinator.sync() }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $showHealthSync) {
                HealthSyncView(settings: settings, coordinator: coordinator)
            }
        }
    }

    private var visibleRuns: [Run] {
        runs.filter { $0.activity == activity && $0.startDate >= settings.startDate }
    }

    private func runsSubtitle(runCount: Int) -> String {
        "\(runCount) \(activity.pluralTitle.lowercased()) since \(shortDate(settings.startDate))"
    }

    private func refresh() {
        Task { await coordinator.sync() }
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

private struct EmptyStateView: View {
    @Environment(\.theme) private var theme
    let activity: CardioActivity
    let syncState: SyncCoordinator.State
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("$ ls \(activity.pluralTitle.lowercased())/")
                .terminalFont(16, weight: .bold)
                .foregroundColor(theme.cyan)
            switch syncState {
            case .syncing:
                Text("// syncing…")
                    .terminalFont(12)
                    .foregroundColor(theme.comment)
            case .error(let msg):
                Text("[error] \(msg)")
                    .terminalFont(12)
                    .foregroundColor(theme.red)
                    .multilineTextAlignment(.center)
                Button("[ retry ]", action: onRetry)
                    .buttonStyle(TerminalButtonStyle(color: theme.cyan))
            case .idle:
                Text("// no \(activity.pluralTitle.lowercased()) found since your start date")
                    .terminalFont(12)
                    .foregroundColor(theme.comment)
                Text("// if this looks wrong, check Health permissions")
                    .terminalFont(12)
                    .foregroundColor(theme.comment)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("[ open settings ]", destination: url)
                        .terminalFont(12, weight: .bold)
                        .foregroundColor(theme.yellow)
                }
                Button("[ retry ]", action: onRetry)
                    .buttonStyle(TerminalButtonStyle(color: theme.cyan))
            }
        }
        .padding(24)
    }
}
