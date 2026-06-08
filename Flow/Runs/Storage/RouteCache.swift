import Foundation
import CoreLocation

/// In-memory cache of route locations + derived sparkline data, keyed by run id.
/// Bounded LRU. Fetches from HealthKit on demand.
/// Actor-isolated so concurrent calls from many list rows are serialised safely.
actor RouteCache {
    static let shared = RouteCache()

    struct Entry: Sendable {
        var locations: [CLLocation]
        var paceBuckets: [Double]
    }

    private let limit = 48
    private var cache: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var inflight: [UUID: Task<Entry, Error>] = [:]

    func cached(_ id: UUID) -> Entry? {
        guard let entry = cache[id] else { return nil }
        touch(id)
        return entry
    }

    func load(id: UUID, fetch: @Sendable @escaping () async throws -> [CLLocation]) async throws -> Entry {
        if let entry = cache[id] {
            touch(id)
            return entry
        }
        if let task = inflight[id] { return try await task.value }

        let task = Task<Entry, Error> {
            let locs = try await fetch()
            let buckets = RunMetrics.paceBuckets(from: locs, count: 32)
            return Entry(locations: locs, paceBuckets: buckets)
        }
        inflight[id] = task

        do {
            let entry = try await task.value
            store(entry, for: id)
            inflight[id] = nil
            return entry
        } catch {
            inflight[id] = nil
            throw error
        }
    }

    private func store(_ entry: Entry, for id: UUID) {
        cache[id] = entry
        touch(id)
        while order.count > limit {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private func touch(_ id: UUID) {
        if let index = order.firstIndex(of: id) {
            order.remove(at: index)
        }
        order.append(id)
    }
}
