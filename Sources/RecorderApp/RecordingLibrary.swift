import Foundation

struct RecordingSessionMetadata: Codable, Equatable, Hashable {
    var title: String?
    var tags: [String]
    var isFavorite: Bool

    init(title: String? = nil, tags: [String] = [], isFavorite: Bool = false) {
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.tags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.isFavorite = isFavorite
    }
}

enum RecordingSessionMetadataStore {
    static let fileName = "recording-info.json"

    static func load(in folder: URL) -> RecordingSessionMetadata {
        guard let data = try? Data(contentsOf: fileURL(in: folder)) else {
            return RecordingSessionMetadata()
        }
        return (try? JSONDecoder.pretty.decode(RecordingSessionMetadata.self, from: data)) ?? RecordingSessionMetadata()
    }

    static func save(_ metadata: RecordingSessionMetadata, in folder: URL) throws {
        let data = try JSONEncoder.pretty.encode(metadata)
        try data.write(to: fileURL(in: folder), options: .atomic)
    }

    static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }
}

struct TranscriptionState: Codable, Equatable {
    enum Phase: String, Codable {
        case queued
        case uploading
        case transcribing
        case completed
        case failed
        case cancelled
        case interrupted
    }

    var phase: Phase
    var message: String
    var startedAt: Date
    var finishedAt: Date?
}

enum TranscriptionStateStore {
    static let fileName = "transcription-state.json"

    static func load(in folder: URL) throws -> TranscriptionState? {
        let url = fileURL(in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.pretty.decode(TranscriptionState.self, from: Data(contentsOf: url))
    }

    static func save(_ state: TranscriptionState, in folder: URL) throws {
        let data = try JSONEncoder.pretty.encode(state)
        try data.write(to: fileURL(in: folder), options: .atomic)
    }

    static func markCancelled(in folder: URL, at date: Date = Date()) throws {
        let existing = try load(in: folder)
        try save(
            .init(
                phase: .cancelled,
                message: "Transcription cancelled",
                startedAt: existing?.startedAt ?? date,
                finishedAt: date
            ),
            in: folder
        )
    }

    static func markInterruptedIfNeeded(in folder: URL, at date: Date = Date()) throws -> TranscriptionState? {
        guard var state = try load(in: folder), [.queued, .uploading, .transcribing].contains(state.phase) else {
            return try load(in: folder)
        }
        state.phase = .interrupted
        state.message = "Transcription interrupted. You can start it again."
        state.finishedAt = date
        try save(state, in: folder)
        return state
    }

    static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }
}

enum TranscriptDocumentStore {
    static let editableFileName = "transcript.txt"
    static let qwenTranscriptFileName = "transcript_qwen3_asr_1_7b_8bit_yue_trad.txt"

    static func read(in folder: URL) throws -> String {
        let editable = editableURL(in: folder)
        if FileManager.default.fileExists(atPath: editable.path) {
            return try String(contentsOf: editable, encoding: .utf8)
        }
        return try String(contentsOf: qwenURL(in: folder), encoding: .utf8)
    }

    static func save(_ text: String, in folder: URL) throws {
        try text.write(to: editableURL(in: folder), atomically: true, encoding: .utf8)
    }

    static func editableURL(in folder: URL) -> URL {
        folder.appendingPathComponent(editableFileName)
    }

    static func qwenURL(in folder: URL) -> URL {
        folder.appendingPathComponent(qwenTranscriptFileName)
    }
}

struct AudioHealthAssessment: Equatable {
    enum Status: Equatable {
        case ok
        case warning
        case neutral
    }

    struct Input: Equatable {
        let title: String
        let detail: String
        let status: Status
    }

    let system: Input
    let mic: Input
}

enum AudioHealthAdvisor {
    static func assessment(
        systemLevel: LevelSnapshot,
        micLevel: LevelSnapshot,
        isMicMuted: Bool,
        isMonitoring: Bool,
        isRecording: Bool
    ) -> AudioHealthAssessment {
        let context = isRecording ? "during recording" : (isMonitoring ? "while monitoring" : "before recording")
        let system = input(title: "System audio", level: systemLevel, context: context)
        let mic: AudioHealthAssessment.Input
        if isMicMuted {
            mic = .init(title: "Mic muted", detail: "Recorder microphone is muted.", status: .neutral)
        } else {
            mic = input(title: "Microphone", level: micLevel, context: context)
        }
        return .init(system: system, mic: mic)
    }

    private static func input(title: String, level: LevelSnapshot, context: String) -> AudioHealthAssessment.Input {
        if level.isSilent {
            return .init(title: title, detail: "No signal detected \(context).", status: .warning)
        }
        if level.isClipping {
            return .init(title: title, detail: "Signal is clipping \(context).", status: .warning)
        }
        return .init(title: title, detail: "Signal detected \(context).", status: .ok)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var pretty: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
