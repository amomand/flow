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

    static func splits(from locations: [CLLocation], reconcileElevationTo authoritativeGain: Double? = nil) -> [Split] {
        guard locations.count >= 2 else { return [] }
        let altitudes = smoothedAltitudes(from: locations)

        struct RawSplit { let kmIndex: Int; let duration: Double; let gain: Double }
        var raws: [RawSplit] = []
        var nextKmIndex = 1
        var splitStartTime = locations.first!.timestamp
        var elevAccum = 0.0
        var cumDist = 0.0

        for i in 1..<locations.count {
            let previous = locations[i - 1]
            let current = locations[i]
            let previousAltitude = altitudes[i - 1]
            let currentAltitude = altitudes[i]
            let segmentStartDist = cumDist
            let segmentDistance = current.distance(from: previous)
            guard segmentDistance > 0 else { continue }

            let segmentEndDist = segmentStartDist + segmentDistance
            let segmentDuration = current.timestamp.timeIntervalSince(previous.timestamp)
            let segmentAltitudeDelta = currentAltitude - previousAltitude
            var localStartDist = segmentStartDist
            var localStartAltitude = previousAltitude

            while Double(nextKmIndex) * 1000.0 <= segmentEndDist {
                let boundaryDist = Double(nextKmIndex) * 1000.0
                let fraction = (boundaryDist - segmentStartDist) / segmentDistance
                let boundaryTime = previous.timestamp.addingTimeInterval(segmentDuration * fraction)
                let boundaryAltitude = previousAltitude + segmentAltitudeDelta * fraction
                let altitudeDelta = boundaryAltitude - localStartAltitude
                if altitudeDelta > 0 { elevAccum += altitudeDelta }

                let dt = boundaryTime.timeIntervalSince(splitStartTime)
                raws.append(RawSplit(kmIndex: nextKmIndex, duration: dt, gain: elevAccum))

                nextKmIndex += 1
                splitStartTime = boundaryTime
                elevAccum = 0
                localStartDist = boundaryDist
                localStartAltitude = boundaryAltitude
            }

            let remainingAltitudeDelta = currentAltitude - localStartAltitude
            if segmentEndDist > localStartDist, remainingAltitudeDelta > 0 {
                elevAccum += remainingAltitudeDelta
            }
            cumDist = segmentEndDist
        }

        let gpsTotal = raws.reduce(0) { $0 + $1.gain }
        let scale: Double
        if let target = authoritativeGain, target > 0, gpsTotal > 0 {
            scale = target / gpsTotal
        } else {
            scale = 1
        }

        return raws.map {
            Split(kmIndex: $0.kmIndex, durationSeconds: $0.duration, elevationGainMetres: $0.gain * scale)
        }
    }

    static func smoothedAltitudes(from locations: [CLLocation], window: Int = 5) -> [Double] {
        let altitudes = locations.map(\.altitude)
        guard altitudes.count > 2, window > 1 else { return altitudes }
        let half = window / 2
        var out = [Double](repeating: 0, count: altitudes.count)
        for i in altitudes.indices {
            let lower = max(0, i - half)
            let upper = min(altitudes.count - 1, i + half)
            var sum = 0.0
            for j in lower...upper { sum += altitudes[j] }
            out[i] = sum / Double(upper - lower + 1)
        }
        return out
    }

    static func downsampledRoutePoints(from locations: [CLLocation], maxPoints: Int = 120) -> [Double] {
        guard locations.count >= 2, maxPoints >= 2 else { return [] }
        let stride = max(1, locations.count / maxPoints)
        var points: [Double] = []
        var index = 0
        while index < locations.count {
            let coordinate = locations[index].coordinate
            points.append(coordinate.latitude)
            points.append(coordinate.longitude)
            index += stride
        }
        if let last = locations.last?.coordinate,
           points.count >= 2,
           points[points.count - 2] != last.latitude || points[points.count - 1] != last.longitude {
            points.append(last.latitude)
            points.append(last.longitude)
        }
        return points
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
        let altitudes = smoothedAltitudes(from: locations)
        let step = max(1, locations.count / count)
        var cumDist = 0.0
        var samples: [MetricSample] = [MetricSample(id: 0, distanceKm: 0, value: altitudes[0])]

        for i in 1..<locations.count {
            cumDist += locations[i].distance(from: locations[i - 1])
            if i % step == 0 || i == locations.count - 1 {
                samples.append(MetricSample(id: samples.count, distanceKm: cumDist / 1000.0, value: altitudes[i]))
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
