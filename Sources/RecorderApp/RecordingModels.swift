import Foundation

struct RecordingHealthReport: Equatable {
    var systemSignalSeen = false
    var micSignalSeen = false
    var clippingEvents = 0
    var droppedBuffers = 0
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
        return parts.joined(separator: ", ")
    }
}

struct RecordingResult: Equatable {
    let folderURL: URL
    let recordingURL: URL
    let health: RecordingHealthReport
}

enum RecordingEngineError: LocalizedError {
    case noSystemDevice
    case noMicDevice
    case cannotCreateFolder
    case unsupportedFormat
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSystemDevice:
            return "請先選擇 system audio input，例如 BlackHole 2ch。"
        case .noMicDevice:
            return "請先選擇 microphone input。"
        case .cannotCreateFolder:
            return "無法建立錄音輸出資料夾。"
        case .unsupportedFormat:
            return "目前輸入裝置格式不支援錄音。"
        case let .engineStartFailed(message):
            return "錄音引擎啟動失敗：\(message)"
        }
    }
}
