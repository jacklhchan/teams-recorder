import Foundation

struct RecordingHealthReport: Equatable {
    var systemSignalSeen = false
    var micSignalSeen = false
    var clippingEvents = 0
    var droppedBuffers = 0
    var conversionFailures = 0
    var lateFrames = 0
    var systemDisconnects = 0
    var microphoneDisconnects = 0
    var streamFailures = 0
    var timelineDiscontinuities = 0
    var startedAt: Date?
    var endedAt: Date?

    var summary: String {
        var parts: [String] = []
        parts.append(systemSignalSeen ? "system audio ok" : "no system audio")
        parts.append(micSignalSeen ? "mic ok" : "no mic signal")
        if clippingEvents > 0 {
            parts.append("\(clippingEvents) clipping events")
        }
        if droppedBuffers > 0 {
            parts.append("\(droppedBuffers) dropped buffers")
        }
        if conversionFailures > 0 {
            parts.append("\(conversionFailures) conversion failures")
        }
        if lateFrames > 0 {
            parts.append("\(lateFrames) late frames")
        }
        if systemDisconnects > 0 {
            parts.append("\(systemDisconnects) system capture disconnects")
        }
        if microphoneDisconnects > 0 {
            parts.append("\(microphoneDisconnects) microphone disconnects")
        }
        if streamFailures > 0 {
            parts.append("\(streamFailures) stream failures")
        }
        if timelineDiscontinuities > 0 {
            parts.append("\(timelineDiscontinuities) timeline discontinuities")
        }
        return parts.joined(separator: ", ")
    }
}

struct RecordingResult: Equatable {
    let folderURL: URL
    let recordingURL: URL
    let health: RecordingHealthReport
}

enum RecordingEngineError: LocalizedError {
    case cannotCreateFolder
    case unsupportedFormat
    case captureStartFailed(String)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateFolder:
            return "無法建立錄音輸出資料夾。"
        case .unsupportedFormat:
            return "目前音訊格式不支援錄音。"
        case let .captureStartFailed(message):
            return "原生音訊擷取啟動失敗：\(message)"
        case let .writerFailed(message):
            return "錄音檔案無法建立：\(message)"
        }
    }
}
