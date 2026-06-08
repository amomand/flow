import SwiftUI
import SwiftData
import CoreLocation

struct RunRowView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    let run: Run

    @State private var paceBuckets: [Double] = []
    @State private var coordinates: [CLLocationCoordinate2D] = []
    @State private var didLoad = false
    @State private var loadFailed = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("$")
                        .foregroundColor(theme.green)
                    Text("\(run.activity.commandName) --date")
                        .foregroundColor(theme.fg)
                    Text(run.isoDate)
                        .foregroundColor(theme.cyan)
                }
                .terminalFont(12)

                HStack(spacing: 8) {
                    metric(run.formattedDistance, color: theme.fg)
                    dot
                    metric(run.formattedDuration, color: theme.fg)
                    dot
                    metric(run.formattedElevation, color: theme.orange)
                }
                .terminalFont(15, weight: .semibold)

                if paceBuckets.count >= 2 {
                    SparklineView(values: paceBuckets, height: 22)
                }
            }

            Spacer(minLength: 4)

            routeGlyph
        }
        .terminalCard()
        .task(id: run.id) { await loadRoute() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder private var routeGlyph: some View {
        if coordinates.count >= 2 {
            RoutePolylineThumbnailView(coordinates: coordinates, height: 52)
                .frame(width: 74)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.darkCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(theme.cyan.opacity(0.35), lineWidth: 1)
                        )
                )
        } else {
            let label = loadFailed ? "!" : (didLoad ? "--" : "...")
            let color = loadFailed ? theme.red : theme.comment.opacity(0.6)

            RoundedRectangle(cornerRadius: 4)
                .stroke(theme.comment.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 86, height: 64)
                .overlay {
                    Text(label)
                        .terminalFont(11, weight: .bold)
                        .foregroundColor(color)
                }
        }
    }

    @ViewBuilder private var dot: some View {
        Text("·").foregroundColor(theme.comment)
    }

    private func metric(_ s: String, color: Color) -> some View {
        Text(s).foregroundColor(color)
    }

    private func loadRoute() async {
        if run.hasCachedRoute {
            paceBuckets = run.paceBuckets
            coordinates = run.cachedCoordinates
            didLoad = true
            return
        }

        do {
            let id = run.id
            let entry: RouteCache.Entry
            if let cached = await RouteCache.shared.cached(id) {
                entry = cached
            } else {
                entry = try await RouteCache.shared.load(id: id) {
                    let hk = HealthKitService.shared
                    guard let w = try await hk.fetchWorkout(uuid: id) else { return [] }
                    return try await hk.fetchRoute(for: w)
                }
            }
            paceBuckets = entry.paceBuckets
            coordinates = entry.locations.map(\.coordinate)
            didLoad = true
            persistDerived(from: entry)
        } catch {
            print("[Flow] loadRoute failed for \(run.id): \(error)")
            loadFailed = true
        }
    }

    private func persistDerived(from entry: RouteCache.Entry) {
        guard !run.hasCachedRoute, !entry.paceBuckets.isEmpty else { return }
        run.paceBuckets = entry.paceBuckets
        run.routePoints = RunMetrics.downsampledRoutePoints(from: entry.locations)
        try? modelContext.save()
    }

    private var accessibilitySummary: String {
        "\(run.activity.commandName), \(run.formattedDistance), \(run.formattedDuration), \(run.formattedElevation), \(run.formattedDateHeader)"
    }
}
