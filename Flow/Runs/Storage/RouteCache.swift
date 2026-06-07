import Foundation
import CoreLocation

/// In-memory cache of route locations + derived sparkline data, keyed by run id.
/// Lifetime: the process. Fetches from HealthKit on demand.
/// Actor-isolated so concurrent calls from many list rows are serialised safely.
actor RouteCache {
    static let shared = RouteCache()

    struct Entry: Sendable {
        var locations: [CLLocation]
        var paceBuckets: [Double]
    }

    private var cache: [UUID: Entry] = [:]
    private var inflight: [UUID: Task<Entry, Error>] = [:]

    func cached(_ id: UUID) -> Entry? { cache[id] }

    func load(id: UUID, fetch: @Sendable @escaping () async throws -> [CLLocation]) async throws -> Entry {
        if let entry = cache[id] { return entry }
        if let task = inflight[id] { return try await task.value }

        let task = Task<Entry, Error> {
            let locs = try await fetch()
            let buckets = RunMetrics.paceBuckets(from: locs, count: 32)
            return Entry(locations: locs, paceBuckets: buckets)
        }
        inflight[id] = task

        do {
            let entry = try await task.value
            cache[id] = entry
            inflight[id] = nil
            return entry
        } catch {
            inflight[id] = nil
            throw error
        }
    }
}
