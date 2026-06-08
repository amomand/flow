import SwiftUI
import SwiftData

@main
struct FlowApp: App {
    private let runStorage: RunStorage
    @State private var routineStore = RoutineStore()
    @State private var runSettings = AppSettings.shared
    @State private var syncCoordinator: SyncCoordinator

    init() {
        let runStorage = RunStorage.create()
        self.runStorage = runStorage
        _syncCoordinator = State(initialValue: SyncCoordinator(modelContainer: runStorage.container))
    }

    var body: some Scene {
        WindowGroup {
            FlowRootView(
                routineStore: routineStore,
                runSettings: runSettings,
                syncCoordinator: syncCoordinator
            )
                .preferredColorScheme(.dark)
                .modelContainer(runStorage.container)
        }
    }
}

private struct RunStorage {
    let container: ModelContainer

    static func create() -> RunStorage {
        do {
            return RunStorage(container: try ModelContainer(for: Run.self))
        } catch {
            print("Failed to create persistent run model container; using in-memory cache: \(error)")
            do {
                let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
                return RunStorage(container: try ModelContainer(for: Run.self, configurations: configuration))
            } catch {
                preconditionFailure("Failed to create in-memory run model container: \(error)")
            }
        }
    }
}

struct FlowRootView: View {
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Run.startDate, order: .reverse) private var workouts: [Run]

    let routineStore: RoutineStore
    let runSettings: AppSettings
    let syncCoordinator: SyncCoordinator

    var body: some View {
        let activities = visibleActivities

        Group {
            if activities.isEmpty {
                strengthView
            } else {
                TabView {
                    strengthView
                        .tabItem {
                            Label("Strength", systemImage: "figure.strengthtraining.traditional")
                        }

                    ForEach(activities) { activity in
                        RunsRootView(activity: activity, settings: runSettings, coordinator: syncCoordinator)
                            .tabItem {
                                Label(activity.pluralTitle, systemImage: activity.tabImageName)
                            }
                    }
                }
                .tint(theme.blue)
            }
        }
        .task { await syncIfNeeded() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await syncIfNeeded() }
        }
    }

    private var strengthView: some View {
        RoutineListView(store: routineStore, settings: runSettings, coordinator: syncCoordinator)
    }

    private var visibleActivities: [CardioActivity] {
        CardioActivity.allCases.filter { activity in
            workouts.contains { $0.activity == activity && $0.startDate >= runSettings.startDate }
        }
    }

    private func syncIfNeeded() async {
        guard runSettings.hasOnboarded else { return }
        await syncCoordinator.sync(startDate: runSettings.startDate)
    }
}

struct RunsRootView: View {
    @Environment(\.theme) private var theme
    let activity: CardioActivity
    let settings: AppSettings
    let coordinator: SyncCoordinator

    var body: some View {
        RunListView(activity: activity, settings: settings, coordinator: coordinator)
        .tint(theme.cyan)
    }
}
