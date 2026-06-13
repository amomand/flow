import SwiftUI
import SwiftData

@main
struct FlowApp: App {
    let runContainer: ModelContainer
    @State private var routineStore = RoutineStore()
    @State private var historyStore = StrengthHistoryStore()
    @State private var runSettings = AppSettings.shared
    @State private var syncCoordinator: SyncCoordinator

    init() {
        runContainer = Self.makeRunContainer()
        _syncCoordinator = State(initialValue: SyncCoordinator(modelContainer: runContainer))
    }

    var body: some Scene {
        WindowGroup {
            FlowRootView(
                routineStore: routineStore,
                historyStore: historyStore,
                runSettings: runSettings,
                syncCoordinator: syncCoordinator
            )
                .preferredColorScheme(.dark)
                .modelContainer(runContainer)
        }
    }

    private static func makeRunContainer() -> ModelContainer {
        let schema = Schema([Run.self])
        let config = ModelConfiguration("RunCache", schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            print("[Flow] Run ModelContainer open failed (\(error)); rebuilding cache store.")
            destroyRunStore()
            if let fresh = try? ModelContainer(for: schema, configurations: config) {
                return fresh
            }
            let memory = ModelConfiguration("RunCacheMemory", schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: memory)
        }
    }

    private static func destroyRunStore() {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        for name in ["RunCache.store", "default.store"] {
            let base = appSupport.appendingPathComponent(name)
            for suffix in ["", "-shm", "-wal"] {
                try? fm.removeItem(at: URL(fileURLWithPath: base.path + suffix))
            }
        }
    }
}

struct FlowRootView: View {
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Run.startDate, order: .reverse) private var workouts: [Run]

    let routineStore: RoutineStore
    let historyStore: StrengthHistoryStore
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
        RoutineListView(store: routineStore, historyStore: historyStore, settings: runSettings, coordinator: syncCoordinator)
    }

    private var visibleActivities: [CardioActivity] {
        CardioActivity.allCases.filter { activity in
            workouts.contains { $0.activity == activity && $0.startDate >= runSettings.startDate }
        }
    }

    private func syncIfNeeded() async {
        guard runSettings.hasOnboarded else { return }
        await syncCoordinator.sync()
        await historyStore.syncHealthKitMetricsForRecentWorkouts()
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
