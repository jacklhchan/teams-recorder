import XCTest
@testable import RecorderApp

final class MeetingIntelligenceObservedSnapshotAdapterTests: XCTestCase {
    func testPreservesFeatureRevisionAndTypedSessionIdentity() throws {
        let folder = RecordingLibraryURLIdentity.normalized(
            URL(fileURLWithPath: "/tmp/meeting-intelligence-observed-session")
        )
        let session = RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .distantPast,
            duration: 0,
            fileSize: 0,
            metadata: .init(title: "Canonical title")
        )
        let identity = try XCTUnwrap(
            MeetingIntelligenceSessionPresentationIdentity(session: session)
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

        let observed = try XCTUnwrap(
            MeetingIntelligenceObservedSnapshotAdapter.make(
                featureRevision: 42,
                sessionPresentation: .init(
                    identity: identity,
                    presentation: presentation
                ),
                canonicalSession: session,
                titleIsProtected: presentation.titleIsProtected
            )
        )

        XCTAssertEqual(observed.featureRevision, 42)
        XCTAssertEqual(observed.identity, identity)
        XCTAssertEqual(observed.phase, .ready)
        XCTAssertEqual(observed.displayedTitle, "Generated title")
        XCTAssertFalse(observed.titleIsProtected)
    }
}
