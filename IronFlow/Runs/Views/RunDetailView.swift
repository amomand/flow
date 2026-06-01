import SwiftUI
import MapKit
import Charts
import CoreLocation

struct RunDetailView: View {
    @Environment(\.theme) private var theme
    let run: Run

    @State private var entry: RouteCache.Entry?
    @State private var splits: [Split] = []
    @State private var elevation: [MetricSample] = []
    @State private var routeDistanceKm = 0.0

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let entry, entry.locations.count >= 2 {
                        mapView(locations: entry.locations)
                    }
                    if let entry, entry.paceBuckets.count >= 2 {
                        SectionHeader(text: "PACE")
                        paceChart(buckets: entry.paceBuckets)
                    }
                    if !elevation.isEmpty {
                        SectionHeader(text: "ELEVATION")
                        elevationChart(samples: elevation)
                    }
                    if !splits.isEmpty {
                        SectionHeader(text: "SPLITS")
                        splitsTable
                    }
                    SectionHeader(text: "HEART RATE")
                    hrBlock
                }
                .padding(16)
            }
        }
        .navigationTitle(run.formattedDateHeader)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(theme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: run.id) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("$ \(run.activity.commandName) --date \(run.isoDate)")
                .terminalFont(13)
                .foregroundColor(theme.green)
            HStack(spacing: 10) {
                Text(run.formattedDistance).foregroundColor(theme.fg)
                Text("·").foregroundColor(theme.comment)
                Text(run.formattedDuration).foregroundColor(theme.fg)
                Text("·").foregroundColor(theme.comment)
                Text(run.formattedElevation).foregroundColor(theme.orange)
            }
            .terminalFont(18, weight: .bold)
            Text("started \(formattedTime(run.startDate))")
                .terminalFont(11)
                .foregroundColor(theme.comment)
        }
        .terminalCard()
    }

    private func mapView(locations: [CLLocation]) -> some View {
        let coords = locations.map { $0.coordinate }
        let region = boundingRegion(for: coords)
        return Map(initialPosition: .region(region)) {
            MapPolyline(coordinates: coords)
                .stroke(theme.cyan, lineWidth: 3)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.comment.opacity(0.3), lineWidth: 1))
    }

    private func paceChart(buckets: [Double]) -> some View {
        let samples = paceSamples(from: buckets)
        let domainEnd = chartDomainEnd(for: samples)
        return Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("km", sample.distanceKm), y: .value("pace", sample.value))
                    .foregroundStyle(theme.magenta)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(theme.comment.opacity(0.2))
                AxisValueLabel {
                    if let secs = value.as(Double.self) {
                        Text(paceLabel(secs)).terminalFont(9).foregroundColor(theme.comment)
                    }
                }
            }
        }
        .chartXAxis { distanceAxisMarks() }
        .chartXScale(domain: 0...domainEnd)
        .frame(height: 140)
        .terminalCard()
    }

    private func elevationChart(samples: [MetricSample]) -> some View {
        let domainEnd = chartDomainEnd(for: samples)
        return Chart {
            ForEach(samples) { sample in
                AreaMark(x: .value("km", sample.distanceKm), y: .value("alt", sample.value))
                    .foregroundStyle(theme.orange.opacity(0.4))
                LineMark(x: .value("km", sample.distanceKm), y: .value("alt", sample.value))
                    .foregroundStyle(theme.orange)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(theme.comment.opacity(0.2))
                AxisValueLabel {
                    if let m = value.as(Double.self) {
                        Text("\(Int(m))m").terminalFont(9).foregroundColor(theme.comment)
                    }
                }
            }
        }
        .chartXAxis { distanceAxisMarks() }
        .chartXScale(domain: 0...domainEnd)
        .frame(height: 140)
        .terminalCard()
    }

    private var splitsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(splits) { split in
                HStack {
                    Text("km \(split.kmIndex)")
                        .foregroundColor(theme.comment)
                        .frame(width: 60, alignment: .leading)
                    Text(split.formattedPace)
                        .foregroundColor(theme.fg)
                    Spacer()
                    Text("+\(Int(split.elevationGainMetres.rounded()))m")
                        .foregroundColor(theme.orange)
                }
                .terminalFont(12)
            }
        }
        .terminalCard()
    }

    private var hrBlock: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading) {
                Text("avg").terminalFont(10).foregroundColor(theme.comment)
                Text(run.avgHeartRate.map { "\(Int($0.rounded()))" } ?? "--")
                    .terminalFont(18, weight: .bold)
                    .foregroundColor(theme.red)
            }
            VStack(alignment: .leading) {
                Text("max").terminalFont(10).foregroundColor(theme.comment)
                Text(run.maxHeartRate.map { "\(Int($0.rounded()))" } ?? "--")
                    .terminalFont(18, weight: .bold)
                    .foregroundColor(theme.red)
            }
            Spacer()
        }
        .terminalCard()
    }

    private func load() async {
        do {
            let id = run.id
            if let cached = await RouteCache.shared.cached(id) {
                await MainActor.run { self.applyEntry(cached) }
                return
            }
            let result = try await RouteCache.shared.load(id: id) {
                let hk = HealthKitService.shared
                guard let w = try await hk.fetchWorkout(uuid: id) else { return [] }
                return try await hk.fetchRoute(for: w)
            }
            await MainActor.run { self.applyEntry(result) }
        } catch {
            print("[Flow] RunDetailView load failed for \(run.id): \(error)")
        }
    }

    private func applyEntry(_ e: RouteCache.Entry) {
        entry = e
        splits = RunMetrics.splits(from: e.locations)
        elevation = RunMetrics.elevationSamples(from: e.locations)
        routeDistanceKm = RunMetrics.totalDistanceKm(from: e.locations)
    }

    private func boundingRegion(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard !coords.isEmpty else {
            return MKCoordinateRegion(center: .init(latitude: 0, longitude: 0), span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05))
        }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.3, 0.005), longitudeDelta: max((maxLon - minLon) * 1.3, 0.005))
        return MKCoordinateRegion(center: center, span: span)
    }

    private func paceLabel(_ secs: Double) -> String {
        let total = Int(secs.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    private func paceSamples(from buckets: [Double]) -> [MetricSample] {
        guard buckets.count >= 2 else { return [] }
        let maxDistance = max(routeDistanceKm > 0 ? routeDistanceKm : run.distanceKm, 0.1)
        return buckets.enumerated().map { idx, value in
            let distance = maxDistance * Double(idx) / Double(buckets.count - 1)
            return MetricSample(id: idx, distanceKm: distance, value: value)
        }
    }

    private func chartDomainEnd(for samples: [MetricSample]) -> Double {
        max(samples.last?.distanceKm ?? routeDistanceKm, 0.1)
    }

    private func distanceAxisMarks() -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(theme.comment.opacity(0.18))
            AxisTick().foregroundStyle(theme.comment.opacity(0.45))
            AxisValueLabel {
                if let km = value.as(Double.self) {
                    Text(distanceLabel(km))
                        .terminalFont(9)
                        .foregroundColor(theme.comment)
                }
            }
        }
    }

    private func distanceLabel(_ km: Double) -> String {
        if run.distanceKm < 10 {
            return String(format: "%.1fkm", km)
        }
        return "\(Int(km.rounded()))km"
    }

    private func formattedTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: d)
    }
}
