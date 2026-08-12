import SwiftUI

struct RecordingHealthView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let presentation = RecordingHealthPresentation.make(
            report: model.lastHealthReport
        )

        VStack(alignment: .leading, spacing: 16) {
            Text("Recording Health")
                .font(.largeTitle.weight(.semibold))

            switch presentation.status {
            case .unavailable:
                VStack(alignment: .leading, spacing: 6) {
                    Text("No completed recording health report yet.")
                        .font(.headline)
                    Text("Finish a recording to review capture results.")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("recorder.health.empty")
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: "recorder.health.empty",
                        label: "No completed recording health report yet. Finish a recording to review capture results."
                    )
                )
            case .good, .attention:
                report(presentation)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: "recorder.destination.health"
            )
        )
        .accessibilityIdentifier("recorder.destination.health")
        .navigationTitle("Health")
    }

    @ViewBuilder
    private func report(_ presentation: RecordingHealthPresentation) -> some View {
        Label(
            presentation.title,
            systemImage: presentation.status == .good
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill"
        )
        .font(.headline)
        .foregroundStyle(presentation.status == .good ? .green : .orange)
        .accessibilityIdentifier("recorder.health.status")
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: "recorder.health.status",
                label: presentation.title
            )
        )

        VStack(alignment: .leading, spacing: 8) {
            if let systemAudioText = presentation.systemAudioText {
                Label(
                    systemAudioText,
                    systemImage: systemAudioText == "System audio captured"
                        ? "checkmark.circle.fill"
                        : "speaker.slash.fill"
                )
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: "recorder.health.system-audio",
                        label: systemAudioText
                    )
                )
            }
            if let microphoneText = presentation.microphoneText {
                Label(
                    microphoneText,
                    systemImage: microphoneText == "Mic captured"
                        ? "checkmark.circle.fill"
                        : "mic.slash.fill"
                )
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: "recorder.health.microphone",
                        label: microphoneText
                    )
                )
            }
        }

        if !presentation.counters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Capture Counters")
                    .font(.headline)
                ForEach(presentation.counters, id: \.identifier) { counter in
                    Text("\(counter.count) \(counter.label)")
                        .accessibilityIdentifier(
                            "recorder.health.counter.\(counter.identifier)"
                        )
                        .background(
                            RecorderDestinationAccessibilityMarker(
                                identifier: "recorder.health.counter.\(counter.identifier)",
                                label: "\(counter.count) \(counter.label)"
                            )
                        )
                }
            }
            .accessibilityIdentifier("recorder.health.counters")
            .background(
                RecorderDestinationAccessibilityMarker(
                    identifier: "recorder.health.counters"
                )
            )
        }
    }
}
