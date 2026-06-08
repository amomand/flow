import CoreLocation
import XCTest
@testable import Flow

final class RunMetricsTests: XCTestCase {
    func testPaceBucketsUseDistanceAndTime() {
        let start = Date(timeIntervalSince1970: 10_000)
        let locations = [
            location(latitude: 51.0, altitude: 0, timestamp: start),
            location(latitude: 51.009, altitude: 0, timestamp: start.addingTimeInterval(300))
        ]

        let buckets = RunMetrics.paceBuckets(from: locations, count: 1)
        let distance = locations[1].distance(from: locations[0])
        let expected = 300 / (distance / 1000)

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0], expected, accuracy: 0.1)
    }

    func testElevationSplitsReconcileToAuthoritativeTotal() {
        let start = Date(timeIntervalSince1970: 20_000)
        let locations = [
            location(latitude: 51.000, altitude: 0, timestamp: start),
            location(latitude: 51.009, altitude: 20, timestamp: start.addingTimeInterval(300)),
            location(latitude: 51.018, altitude: 10, timestamp: start.addingTimeInterval(600)),
            location(latitude: 51.027, altitude: 40, timestamp: start.addingTimeInterval(900))
        ]

        let splits = RunMetrics.splits(from: locations, reconcileElevationTo: 15)
        let total = splits.reduce(0) { $0 + $1.elevationGainMetres }

        XCTAssertFalse(splits.isEmpty)
        XCTAssertEqual(total, 15, accuracy: 0.01)
    }

    private func location(latitude: CLLocationDegrees, altitude: CLLocationDistance, timestamp: Date) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -0.1),
            altitude: altitude,
            horizontalAccuracy: 1,
            verticalAccuracy: 1,
            timestamp: timestamp
        )
    }
}
