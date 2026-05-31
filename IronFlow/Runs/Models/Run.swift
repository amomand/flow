import Foundation
import SwiftData

@Model
final class Run {
    @Attribute(.unique) var id: UUID
    var startDate: Date
    var endDate: Date
    var distanceMetres: Double
    var durationSeconds: Double
    var elevationGainMetres: Double?
    var avgHeartRate: Double?
    var maxHeartRate: Double?

    init(
        id: UUID,
        startDate: Date,
        endDate: Date,
        distanceMetres: Double,
        durationSeconds: Double,
        elevationGainMetres: Double? = nil,
        avgHeartRate: Double? = nil,
        maxHeartRate: Double? = nil
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.distanceMetres = distanceMetres
        self.durationSeconds = durationSeconds
        self.elevationGainMetres = elevationGainMetres
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
    }
}

extension Run {
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
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: startDate)
    }

    var isoDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: startDate)
    }
}
