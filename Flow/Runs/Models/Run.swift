import Foundation
import SwiftData
import CoreLocation

enum CardioActivity: String, CaseIterable, Identifiable {
    case running
    case cycling

    var id: String { rawValue }

    var pluralTitle: String {
        switch self {
        case .running: return "Runs"
        case .cycling: return "Rides"
        }
    }

    var headerTitle: String { pluralTitle.uppercased() }

    var commandName: String {
        switch self {
        case .running: return "run"
        case .cycling: return "ride"
        }
    }

    var tabImageName: String {
        switch self {
        case .running: return "figure.run"
        case .cycling: return "figure.outdoor.cycle"
        }
    }

    var accentName: String {
        switch self {
        case .running: return "cyan"
        case .cycling: return "green"
        }
    }
}

@Model
final class Run {
    @Attribute(.unique) var id: UUID
    var activityRawValue: String = CardioActivity.running.rawValue
    var startDate: Date
    var endDate: Date
    var distanceMetres: Double
    var durationSeconds: Double
    var elevationGainMetres: Double?
    var avgHeartRate: Double?
    var maxHeartRate: Double?
    var paceBuckets: [Double] = []
    var routePoints: [Double] = []

    init(
        id: UUID,
        activity: CardioActivity = .running,
        startDate: Date,
        endDate: Date,
        distanceMetres: Double,
        durationSeconds: Double,
        elevationGainMetres: Double? = nil,
        avgHeartRate: Double? = nil,
        maxHeartRate: Double? = nil,
        paceBuckets: [Double] = [],
        routePoints: [Double] = []
    ) {
        self.id = id
        self.activityRawValue = activity.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.distanceMetres = distanceMetres
        self.durationSeconds = durationSeconds
        self.elevationGainMetres = elevationGainMetres
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
        self.paceBuckets = paceBuckets
        self.routePoints = routePoints
    }
}

extension Run {
    var activity: CardioActivity {
        CardioActivity(rawValue: activityRawValue) ?? .running
    }

    var hasCachedRoute: Bool {
        paceBuckets.count >= 2 && routePoints.count >= 4
    }

    var cachedCoordinates: [CLLocationCoordinate2D] {
        guard routePoints.count >= 4 else { return [] }
        var coords: [CLLocationCoordinate2D] = []
        coords.reserveCapacity(routePoints.count / 2)
        var i = 0
        while i + 1 < routePoints.count {
            coords.append(CLLocationCoordinate2D(latitude: routePoints[i], longitude: routePoints[i + 1]))
            i += 2
        }
        return coords
    }

    func clearCachedRoute() {
        paceBuckets = []
        routePoints = []
    }

    var distanceKm: Double { distanceMetres / 1000.0 }

    var formattedDistance: String {
        String(format: "%.1fkm", distanceKm)
    }

    var formattedDuration: String {
        let total = Int(durationSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h\(String(format: "%02d", m))m" }
        return "\(m)m\(String(format: "%02d", s))s"
    }

    var formattedElevation: String {
        guard let gain = elevationGainMetres else { return "+--m" }
        return "+\(Int(gain.rounded()))m"
    }

    var formattedDateHeader: String {
        Self.headerFormatter.string(from: startDate)
    }

    var isoDate: String {
        Self.isoFormatter.string(from: startDate)
    }

    private static let headerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
