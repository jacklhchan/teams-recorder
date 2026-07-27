import SwiftUI

struct TeamsCaptureViabilityProbeView: View {
    @StateObject private var probe = TeamsCaptureViabilityProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Teams Same-Stream Viability Probe")
                .font(.title2)
            Picker("Teams window", selection: $probe.selectedWindowID) {
                ForEach(probe.windows) { window in
                    Text(window.displayName).tag(Optional(window.id))
                }
            }
            Toggle(
                "Show all Teams windows",
                isOn: $probe.showsAllTeamsWindows
            )
            .disabled(probe.isCapturing)
            HStack {
                Button("Refresh Windows") { probe.refreshWindows() }
                Button("Start") { probe.start() }
                    .disabled(probe.isCapturing || probe.selectedWindowID == nil)
                Button("Use Window Filter") { probe.switchToSelectedWindow() }
                    .disabled(!probe.isCapturing || probe.selectedWindowID == nil)
                Button("Use Application Filter") { probe.switchToApplication() }
                    .disabled(!probe.isCapturing)
                Button("Stop and Save") { probe.stop() }
                    .disabled(!probe.isCapturing)
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow { Text("System RMS"); Text(probe.systemRMS.formatted(.number.precision(.fractionLength(4)))) }
                GridRow { Text("Microphone RMS"); Text(probe.microphoneRMS.formatted(.number.precision(.fractionLength(4)))) }
                GridRow { Text("Complete frames"); Text("\(probe.completeFrameCount)") }
                GridRow { Text("Stream identity"); Text(probe.streamIdentity).textSelection(.enabled) }
                GridRow { Text("Filter revision"); Text("\(probe.filterRevision)") }
                GridRow { Text("System PTS gap"); Text("\(Int(probe.systemPTSGap * 1_000)) ms") }
                GridRow { Text("Microphone PTS gap"); Text("\(Int(probe.microphonePTSGap * 1_000)) ms") }
            }
            Text(probe.status)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
        .task { probe.refreshWindows() }
    }
}
