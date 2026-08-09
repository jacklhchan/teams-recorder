import SwiftUI

enum RecorderSettingsSection: String, CaseIterable, Identifiable, Hashable {
    case audio
    case recording
    case transcription
    case aiProvider = "ai-provider"
    case storageShortcuts = "storage-shortcuts"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: "Audio"
        case .recording: "Recording"
        case .transcription: "Transcription"
        case .aiProvider: "AI Provider"
        case .storageShortcuts: "Storage & Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .audio: "speaker.wave.2"
        case .recording: "record.circle"
        case .transcription: "text.bubble"
        case .aiProvider: "sparkles"
        case .storageShortcuts: "internaldrive"
        }
    }
}
