import XCTest
@testable import RecorderApp

final class MeetingIntelligenceFeatureSnapshotTests: XCTestCase {
    func testEmptySnapshotHasStableRevisionAndAliasDoesNotResolve() {
        let folder = RecordingLibraryURLIdentity.normalized(
            URL(fileURLWithPath: "/tmp/meeting-intelligence-feature-session")
        )
        let alias = URL(fileURLWithPath: "/tmp/meeting-intelligence-feature-session/..")
            .appendingPathComponent("meeting-intelligence-feature-session")
        let session = RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .distantPast,
            duration: 0,
            fileSize: 0,
            metadata: .init()
        )
        let aliasSession = RecordingSession(
            id: alias,
            folderURL: alias,
            recordingURL: alias.appendingPathComponent("recording.m4a"),
            createdAt: .distantPast,
            duration: 0,
            fileSize: 0,
            metadata: .init()
        )

        let snapshot = MeetingIntelligenceFeatureSnapshot.empty

        XCTAssertEqual(snapshot.revision, 0)
        XCTAssertNil(snapshot.presentation(for: session))
        XCTAssertNil(snapshot.presentation(for: aliasSession))
    }
}
