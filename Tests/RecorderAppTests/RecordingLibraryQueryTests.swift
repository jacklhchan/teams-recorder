import Foundation
import XCTest
@testable import RecorderApp

final class RecordingLibraryQueryTests: XCTestCase {
    func testEmptyQueryReturnsAllThirteenSessions() {
        let sessions = (0..<13).map { index in
            makeSession(
                name: "meeting-\(index)",
                searchDocument: .init(
                    metadataText: "meeting \(index)",
                    transcriptText: ""
                )
            )
        }

        XCTAssertEqual(
            RecordingLibraryQuery(
                text: "",
                favoritesOnly: false
            ).filter(sessions).count,
            13
        )
    }

    func testQueryMatchesTranscriptParticipantDateSourceAndMeetingType() {
        let session = makeSession(
            name: "meeting-2026-07-29-090000",
            createdAt: Date(timeIntervalSince1970: 1_785_274_200),
            metadata: RecordingSessionMetadata(
                title: "Customer session",
                tags: ["network"],
                source: .teamsAutomatic,
                meetingType: "Technical Workshop",
                participants: ["Alex Chan"]
            ),
            searchDocument: .init(
                metadataText:
                    "Customer session network 2026-07-29 "
                    + "Teams Automatic Technical Workshop Alex Chan",
                transcriptText: "Discuss ClearPass migration and next steps."
            )
        )

        for term in [
            "ClearPass",
            "Alex",
            "2026-07-29",
            "Teams",
            "Workshop"
        ] {
            XCTAssertEqual(
                RecordingLibraryQuery(text: term).filter([session]).map(\.id),
                [session.id],
                "Expected search term \(term) to match"
            )
        }
    }

    func testFavoritesFilterComposesWithTextSearch() {
        let favorite = makeSession(
            name: "favorite",
            metadata: .init(isFavorite: true),
            searchDocument: .init(
                metadataText: "roadmap",
                transcriptText: ""
            )
        )
        let ordinary = makeSession(
            name: "ordinary",
            searchDocument: .init(
                metadataText: "roadmap",
                transcriptText: ""
            )
        )

        XCTAssertEqual(
            RecordingLibraryQuery(
                text: "roadmap",
                favoritesOnly: true
            ).filter([favorite, ordinary]).map(\.id),
            [favorite.id]
        )
    }

    func testTranscriptSnippetIsBoundedAndHighlightsNearbyText() {
        let session = makeSession(
            name: "snippet",
            searchDocument: .init(
                metadataText: "",
                transcriptText:
                    String(repeating: "before ", count: 30)
                    + "ClearPass migration decision"
                    + String(repeating: " after", count: 30)
            )
        )

        let snippet = RecordingLibraryQuery(text: "ClearPass")
            .transcriptSnippet(for: session)

        XCTAssertNotNil(snippet)
        XCTAssertTrue(snippet?.contains("ClearPass") == true)
        XCTAssertLessThanOrEqual(snippet?.count ?? .max, 220)
    }

    func testSearchDocumentReadsAtMostFourMiBOfTranscript() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "library-search-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = Data(
            repeating: Character("a").asciiValue!,
            count:
                RecordingLibrarySearchDocument.maximumTranscriptBytes
                + 32
        )
        try transcript.write(
            to: folder.appendingPathComponent(
                TranscriptDocumentStore.editableFileName
            )
        )

        let document = RecordingLibrarySearchDocument.load(
            folderURL: folder,
            displayName: "Large transcript",
            createdAt: Date(timeIntervalSince1970: 0),
            metadata: .init()
        )

        XCTAssertEqual(
            document.transcriptText.utf8.count,
            RecordingLibrarySearchDocument.maximumTranscriptBytes
        )
    }

    private func makeSession(
        name: String,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        metadata: RecordingSessionMetadata = .init(),
        searchDocument: RecordingLibrarySearchDocument
    ) -> RecordingSession {
        let folder = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        return RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: createdAt,
            duration: 0,
            fileSize: 0,
            metadata: metadata,
            searchDocument: searchDocument
        )
    }
}
