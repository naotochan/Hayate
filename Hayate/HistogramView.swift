import SwiftUI

/// RGB histogram overlay (H key). Draws the three channels as translucent
/// filled curves; values are sqrt-scaled for readability in the shadows.
struct HistogramView: View {
    let data: HistogramData

    var body: some View {
        Canvas { context, size in
            let channels: [([Float], Color)] = [
                (data.red, .red),
                (data.green, .green),
                (data.blue, .blue),
            ]
            for (values, color) in channels {
                guard !values.isEmpty else { continue }
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (i, value) in values.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let scaled = CGFloat(min(sqrt(max(value, 0)), 1))
                    path.addLine(to: CGPoint(x: x, y: size.height * (1 - scaled)))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(color.opacity(0.55)))
            }
        }
        .frame(width: 220, height: 90)
        .background(Color.black.opacity(0.65))
        .cornerRadius(6)
    }
}
