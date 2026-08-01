import XCTest
@testable import RecorderApp

final class MeetingIntelligenceObservedSnapshotIdentityTests: XCTestCase {
    func testRejectsPresentationIdentityFromAnotherCanonicalSession() throws {
        let first = session(at: "/tmp/meeting-intelligence-observed-first")
        let second = session(at: "/tmp/meeting-intelligence-observed-second")
        let firstIdentity = try XCTUnwrap(
            MeetingIntelligenceSessionPresentationIdentity(session: first)
        )
        let presentation = MeetingIntelligencePresentation(
            phase: .ready,
            summary: "Summary",
            suggestedTitle: "Generated title",
            statusMessage: "Ready.",
            model: "gpt-test",
            titleIsProtected: false,
            unavailableReason: nil
        )

        XCTAssertNil(
            MeetingIntelligenceObservedSnapshotAdapter.make(
                featureRevision: 7,
                sessionPresentation: .init(
                    identity: firstIdentity,
                    presentation: presentation
                ),
                canonicalSession: second,
                titleIsProtected: false
            )
        )
    }

    private func session(at path: String) -> RecordingSession {
        let folder = RecordingLibraryURLIdentity.normalized(
            URL(fileURLWithPath: path)
        )
        return RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .distantPast,
            duration: 0,
            fileSize: 0,
            metadata: .init()
        )
    }
}
