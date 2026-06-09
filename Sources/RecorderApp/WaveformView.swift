import SwiftUI

struct WaveformView: View {
    let samples: [Float]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            guard !samples.isEmpty else {
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: midY))
                baseline.addLine(to: CGPoint(x: size.width, y: midY))
                context.stroke(baseline, with: .color(tint.opacity(0.35)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                return
            }

            let count = samples.count
            let step = size.width / CGFloat(count)

            var path = Path()
            for index in 0..<count {
                let sample = CGFloat(samples[index])
                let normalized = min(1, max(0, sample))
                let x = CGFloat(index) * step
                let height = max(2, normalized * size.height)
                path.move(to: CGPoint(x: x, y: midY - height / 2))
                path.addLine(to: CGPoint(x: x, y: midY + height / 2))
            }

            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: min(3, max(1.25, step * 0.45)), lineCap: .round))
        }
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
