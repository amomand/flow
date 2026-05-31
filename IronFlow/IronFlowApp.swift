import SwiftUI
import SwiftData

@main
struct IronFlowApp: App {
    let runContainer: ModelContainer
    @State private var routineStore = RoutineStore()
    @State private var runSettings = AppSettings.shared
    @State private var syncCoordinator: SyncCoordinator

    init() {
        do {
            runContainer = try ModelContainer(for: Run.self)
        } catch {
            fatalError("Failed to create run model container: \(error)")
        }
        _syncCoordinator = State(initialValue: SyncCoordinator(modelContainer: runContainer))
    }

    var body: some Scene {
        WindowGroup {
            FlowRootView(
                routineStore: routineStore,
                runSettings: runSettings,
                syncCoordinator: syncCoordinator
            )
                .preferredColorScheme(.dark)
                .modelContainer(runContainer)
        }
    }
}

struct FlowRootView: View {
    @Environment(\.theme) private var theme
    let routineStore: RoutineStore
    let runSettings: AppSettings
    let syncCoordinator: SyncCoordinator

    var body: some View {
        TabView {
            RoutineListView(store: routineStore)
                .tabItem {
                    Label("Strength", systemImage: "figure.strengthtraining.traditional")
                }

            RunsRootView(settings: runSettings, coordinator: syncCoordinator)
                .tabItem {
                    Label("Runs", systemImage: "figure.run")
                }
        }
        .tint(theme.blue)
    }
}

struct RunsRootView: View {
    @Environment(\.theme) private var theme
    let settings: AppSettings
    let coordinator: SyncCoordinator

    var body: some View {
        Group {
            if settings.hasOnboarded {
                RunListView(settings: settings, coordinator: coordinator)
            } else {
                FirstLaunchView(settings: settings) {
                    Task { await coordinator.sync(startDate: settings.startDate) }
                }
            }
        }
        .tint(theme.cyan)
    }
}
