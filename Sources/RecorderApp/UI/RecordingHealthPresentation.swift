struct RecordingHealthPresentation: Equatable {
    enum Status: Equatable {
        case good
        case attention
        case unavailable
    }

    struct Counter: Equatable {
        let identifier: String
        let label: String
        let count: Int
    }

    let status: Status
    let title: String
    let systemAudioText: String?
    let microphoneText: String?
    let counters: [Counter]

    static func make(report: RecordingHealthReport?) -> Self {
        guard let report else {
            return .init(
                status: .unavailable,
                title: "Recording Health",
                systemAudioText: nil,
                microphoneText: nil,
                counters: []
            )
        }

        let counters = [
            counter("clipping-events", "clipping events", report.clippingEvents),
            counter("dropped-buffers", "dropped buffers", report.droppedBuffers),
            counter("conversion-failures", "conversion failures", report.conversionFailures),
            counter("late-frames", "late frames", report.lateFrames),
            counter("system-disconnects", "system capture disconnects", report.systemDisconnects),
            counter("microphone-disconnects", "microphone disconnects", report.microphoneDisconnects),
            counter("stream-failures", "stream failures", report.streamFailures),
            counter("timeline-discontinuities", "timeline discontinuities", report.timelineDiscontinuities),
            counter("video-dropped-frames", "video frames dropped", report.videoDroppedFrames),
            counter("video-invalid-timestamps", "invalid video timestamps", report.videoInvalidTimestamps),
            counter("video-stall-events", "video stalls", report.videoStallEvents),
            counter("video-filter-failures", "video filter failures", report.videoFilterFailures),
            counter("mux-fallback-events", "audio fallback", report.muxFallbackEvents),
            counter("metadata-write-failures", "metadata write failures", report.metadataWriteFailures)
        ].compactMap { $0 }
        let status: Status = report.systemSignalSeen && report.micSignalSeen && counters.isEmpty
            ? .good
            : .attention

        return .init(
            status: status,
            title: status == .good ? "Capture looks good" : "Capture needs attention",
            systemAudioText: report.systemSignalSeen
                ? "System audio captured"
                : "No system audio",
            microphoneText: report.micSignalSeen ? "Mic captured" : "No mic signal",
            counters: counters
        )
    }

    private static func counter(
        _ identifier: String,
        _ label: String,
        _ count: Int
    ) -> Counter? {
        count > 0 ? .init(identifier: identifier, label: label, count: count) : nil
    }
}
