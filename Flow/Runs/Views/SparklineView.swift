import SwiftUI

/// Inline pace sparkline. Lower pace value = faster, drawn higher.
struct SparklineView: View {
    @Environment(\.theme) private var theme
    let values: [Double]
    var color: Color? = nil
    var height: CGFloat = 28

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }
            let mn = values.min() ?? 0
            let mx = values.max() ?? 1
            let span = max(mx - mn, 0.0001)
            let stepX = size.width / CGFloat(values.count - 1)

            var path = Path()
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * stepX
                // invert: faster (smaller v) plotted higher
                let yNorm = 1.0 - CGFloat((v - mn) / span)
                let y = yNorm * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(color ?? theme.magenta), lineWidth: 1.5)
        }
        .frame(height: height)
    }
}
