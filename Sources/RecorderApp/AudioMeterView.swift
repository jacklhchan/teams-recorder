import SwiftUI

struct AudioMeterView: View {
    let title: String
    let subtitle: String
    let level: LevelSnapshot
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(level.rms)) dBFS")
                    .font(.system(.title3, design: .monospaced, weight: .medium))
                    .foregroundStyle(level.isClipping ? .red : .primary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.secondary.opacity(0.16))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(level.isClipping ? .red : tint)
                        .frame(width: max(4, proxy.size.width * normalizedLevel))
                        .animation(.linear(duration: 1.0 / 60.0), value: normalizedLevel)
                }
            }
            .frame(height: 14)

            WaveformView(samples: level.samples, tint: tint)
                .frame(height: 74)

            HStack(spacing: 14) {
                if level.isSilent {
                    Label("No signal detected", systemImage: "speaker.slash.fill")
                        .foregroundStyle(.orange)
                }
                if level.isClipping {
                    Label("Clipping", systemImage: "waveform.path.badge.exclamationmark")
                        .foregroundStyle(.red)
                }
                Spacer()
                Text("Peak \(Int(level.peak)) dB")
                    .foregroundStyle(.secondary)
                    .font(.system(.callout, design: .monospaced))
            }
            .frame(height: 22)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        )
    }

    private var normalizedLevel: Double {
        let clamped = min(0, max(-60, Double(level.rms)))
        return (clamped + 60) / 60
    }
}
