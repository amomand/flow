import SwiftUI
import CoreLocation

/// Tiny cyan polyline of the route, scaled to fit. No map tiles.
struct RoutePolylineThumbnailView: View {
    @Environment(\.theme) private var theme
    let locations: [CLLocation]
    var height: CGFloat = 60

    var body: some View {
        Canvas { context, size in
            guard locations.count >= 2 else { return }
            let lats = locations.map { $0.coordinate.latitude }
            let lons = locations.map { $0.coordinate.longitude }
            let minLat = lats.min()!, maxLat = lats.max()!
            let minLon = lons.min()!, maxLon = lons.max()!
            let latSpan = max(maxLat - minLat, 0.00001)
            let lonSpan = max(maxLon - minLon, 0.00001)

            // Preserve aspect ratio.
            let scale = min(size.width / CGFloat(lonSpan), size.height / CGFloat(latSpan))
            let drawW = CGFloat(lonSpan) * scale
            let drawH = CGFloat(latSpan) * scale
            let offX = (size.width - drawW) / 2
            let offY = (size.height - drawH) / 2

            var path = Path()
            for (i, loc) in locations.enumerated() {
                let x = offX + CGFloat(loc.coordinate.longitude - minLon) * scale
                // Flip Y: north should be up.
                let y = offY + drawH - CGFloat(loc.coordinate.latitude - minLat) * scale
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(theme.cyan), lineWidth: 1.5)
        }
        .frame(height: height)
    }
}
