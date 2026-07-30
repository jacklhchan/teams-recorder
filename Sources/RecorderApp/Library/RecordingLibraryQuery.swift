import Foundation

struct RecordingLibrarySearchDocument: Equatable, Hashable, Sendable {
    static let maximumTranscriptBytes = 4 * 1_024 * 1_024
    static let empty = RecordingLibrarySearchDocument(
        metadataText: "",
        transcriptText: ""
    )

    let metadataText: String
    let transcriptText: String
    let normalizedText: String

    init(metadataText: String, transcriptText: String) {
        self.metadataText = metadataText
        self.transcriptText = transcriptText
        normalizedText = Self.normalized(
            metadataText + "\n" + transcriptText
        )
    }

    static func load(
        folderURL: URL,
        displayName: String,
        createdAt: Date,
        metadata: RecordingSessionMetadata
    ) -> RecordingLibrarySearchDocument {
        let metadataText = [
            displayName,
            metadata.tags.joined(separator: " "),
            dateFormatter.string(from: createdAt),
            metadata.source.searchLabel,
            metadata.meetingType ?? "",
            metadata.participants.joined(separator: " ")
        ].joined(separator: "\n")

        guard let transcriptURL = TranscriptDocumentStore.resolvedURL(
            in: folderURL
        ) else {
            return .init(
                metadataText: metadataText,
                transcriptText: ""
            )
        }
        return .init(
            metadataText: metadataText,
            transcriptText: boundedText(at: transcriptURL)
        )
    }

    private static func boundedText(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ""
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(
            upToCount: maximumTranscriptBytes + 1
        ) else {
            return ""
        }
        return String(
            decoding: data.prefix(maximumTranscriptBytes),
            as: UTF8.self
        )
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withFullDate,
            .withDashSeparatorInDate
        ]
        return formatter
    }()

    fileprivate static func normalized(_ value: String) -> String {
        value.folding(
            options: [
                .caseInsensitive,
                .diacriticInsensitive,
                .widthInsensitive
            ],
            locale: .current
        )
    }
}

struct RecordingLibraryQuery: Equatable, Sendable {
    let text: String
    let favoritesOnly: Bool

    init(text: String, favoritesOnly: Bool = false) {
        self.text = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.favoritesOnly = favoritesOnly
    }

    func filter(_ sessions: [RecordingSession]) -> [RecordingSession] {
        let needle = RecordingLibrarySearchDocument.normalized(text)
        return sessions.filter { session in
            guard !favoritesOnly || session.isFavorite else {
                return false
            }
            return needle.isEmpty
                || session.searchDocument.normalizedText
                    .contains(needle)
        }
    }

    func transcriptSnippet(
        for session: RecordingSession,
        maximumCharacters: Int = 220
    ) -> String? {
        guard !text.isEmpty else { return nil }
        let transcript = session.searchDocument.transcriptText
        guard let match = transcript.range(
            of: text,
            options: [
                .caseInsensitive,
                .diacriticInsensitive,
                .widthInsensitive
            ]
        ) else {
            return nil
        }

        let context = max(
            0,
            (maximumCharacters - text.count - 2) / 2
        )
        let lower = transcript.index(
            match.lowerBound,
            offsetBy: -context,
            limitedBy: transcript.startIndex
        ) ?? transcript.startIndex
        let upper = transcript.index(
            match.upperBound,
            offsetBy: context,
            limitedBy: transcript.endIndex
        ) ?? transcript.endIndex
        var snippet = String(transcript[lower..<upper])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if lower != transcript.startIndex {
            snippet = "…" + snippet
        }
        if upper != transcript.endIndex {
            snippet += "…"
        }
        return String(snippet.prefix(maximumCharacters))
    }

}

private extension RecordingSource {
    var searchLabel: String {
        switch self {
        case .manual:
            "Manual"
        case .teamsAutomatic:
            "Teams Automatic"
        case .imported:
            "Imported"
        }
    }
}
