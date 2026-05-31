import Foundation
import CoreLocation

struct Split: Identifiable {
    let id = UUID()
    let kmIndex: Int          // 1-based km marker
    let durationSeconds: Double
    let elevationGainMetres: Double

    var paceSecondsPerKm: Double { durationSeconds }
    var formattedPace: String {
        let total = Int(paceSecondsPerKm.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d/km", m, s)
    }
}

struct MetricSample: Identifiable {
    let id: Int
    let distanceKm: Double
    let value: Double
}

enum RunMetrics {
    /// Bucket the route into `count` evenly-distance-spaced pace samples (sec/km).
    static func paceBuckets(from locations: [CLLocation], count: Int = 32) -> [Double] {
        guard locations.count >= 2 else { return [] }

        // Cumulative distance & time arrays.
        var cumDist: [Double] = [0]
        var cumTime: [Double] = [0]
        for i in 1..<locations.count {
            let d = locations[i].distance(from: locations[i-1])
            let t = locations[i].timestamp.timeIntervalSince(locations[i-1].timestamp)
            cumDist.append(cumDist.last! + d)
            cumTime.append(cumTime.last! + max(t, 0))
        }
        let totalDist = cumDist.last ?? 0
        guard totalDist > 0, count > 0 else { return [] }

        let bucketSize = totalDist / Double(count)
        var result: [Double] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            let dStart = Double(i) * bucketSize
            let dEnd = Double(i + 1) * bucketSize
            let tStart = interpolate(target: dStart, xs: cumDist, ys: cumTime)
            let tEnd = interpolate(target: dEnd, xs: cumDist, ys: cumTime)
            let dt = max(tEnd - tStart, 0.001)
            // sec / km
            let pace = dt / (bucketSize / 1000.0)
            result.append(pace)
        }
        return result
    }

    static func splits(from locations: [CLLocation]) -> [Split] {
        guard locations.count >= 2 else { return [] }
        var splits: [Split] = []
        var nextKmIndex = 1
        var splitStartTime = locations.first!.timestamp
        var elevAccum = 0.0
        var cumDist = 0.0

        for i in 1..<locations.count {
            let previous = locations[i - 1]
            let current = locations[i]
            let segmentStartDist = cumDist
            let segmentDistance = current.distance(from: previous)
            guard segmentDistance > 0 else { continue }

            let segmentEndDist = segmentStartDist + segmentDistance
            let segmentDuration = current.timestamp.timeIntervalSince(previous.timestamp)
            let segmentAltitudeDelta = current.altitude - previous.altitude
            var localStartDist = segmentStartDist
            var localStartAltitude = previous.altitude

            while Double(nextKmIndex) * 1000.0 <= segmentEndDist {
                let boundaryDist = Double(nextKmIndex) * 1000.0
                let fraction = (boundaryDist - segmentStartDist) / segmentDistance
                let boundaryTime = previous.timestamp.addingTimeInterval(segmentDuration * fraction)
                let boundaryAltitude = previous.altitude + segmentAltitudeDelta * fraction
                let altitudeDelta = boundaryAltitude - localStartAltitude
                if altitudeDelta > 0 { elevAccum += altitudeDelta }

                let dt = boundaryTime.timeIntervalSince(splitStartTime)
                splits.append(Split(kmIndex: nextKmIndex, durationSeconds: dt, elevationGainMetres: elevAccum))

                nextKmIndex += 1
                splitStartTime = boundaryTime
                elevAccum = 0
                localStartDist = boundaryDist
                localStartAltitude = boundaryAltitude
            }

            let remainingAltitudeDelta = current.altitude - localStartAltitude
            if segmentEndDist > localStartDist, remainingAltitudeDelta > 0 {
                elevAccum += remainingAltitudeDelta
            }
            cumDist = segmentEndDist
        }
        return splits
    }

    /// Elevation values in metres sampled along the route.
    static func elevationProfile(from locations: [CLLocation], count: Int = 64) -> [Double] {
        elevationSamples(from: locations, count: count).map(\.value)
    }

    static func totalDistanceKm(from locations: [CLLocation]) -> Double {
        guard locations.count >= 2 else { return 0 }
        var cumDist = 0.0
        for i in 1..<locations.count {
            cumDist += locations[i].distance(from: locations[i - 1])
        }
        return cumDist / 1000.0
    }

    static func elevationSamples(from locations: [CLLocation], count: Int = 64) -> [MetricSample] {
        guard locations.count >= 2 else { return [] }
        let step = max(1, locations.count / count)
        var cumDist = 0.0
        var samples: [MetricSample] = [MetricSample(id: 0, distanceKm: 0, value: locations[0].altitude)]

        for i in 1..<locations.count {
            cumDist += locations[i].distance(from: locations[i - 1])
            if i % step == 0 || i == locations.count - 1 {
                samples.append(MetricSample(id: samples.count, distanceKm: cumDist / 1000.0, value: locations[i].altitude))
            }
        }
        return samples
    }

    private static func interpolate(target: Double, xs: [Double], ys: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        if target <= xs.first! { return ys.first! }
        if target >= xs.last! { return ys.last! }
        // binary search would be nicer but linear is fine for hundreds of points
        for i in 1..<xs.count {
            if xs[i] >= target {
                let span = xs[i] - xs[i-1]
                if span <= 0 { return ys[i] }
                let frac = (target - xs[i-1]) / span
                return ys[i-1] + frac * (ys[i] - ys[i-1])
            }
        }
        return ys.last!
    }
}
