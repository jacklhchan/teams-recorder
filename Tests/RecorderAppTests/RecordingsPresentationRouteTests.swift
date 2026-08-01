import XCTest
@testable import RecorderApp

@MainActor
final class RecordingsPresentationRouteTests: XCTestCase {
    func testTranscriptRouteResolvesOnlyExactCanonicalSessionID() {
        let session = makeSession(title: "Canonical")
        let route = RecordingsPresentationRoute.transcript(session.id)
        XCTAssertEqual(route.resolvedSession(in: [session])?.id, session.id)
        XCTAssertNil(route.resolvedSession(in: []))
    }

    func testInvalidationClearsMissingSessionAndRejectsSameNameReplacement() {
        let original = makeSession(title: "Shared title")
        let replacement = makeSession(title: "Shared title")
        var route = RecordingsPresentationRoute.transcript(original.id)
        route.invalidateIfMissing(from: [replacement])
        XCTAssertEqual(route, .list)
    }

    func testCapturedActionRevalidatesCanonicalSessionAtInvocationTime() {
        let original = makeSession(title: "Original")
        var currentSessions = [original]
        var invokedIDs: [RecordingSession.ID] = []
        let admission = RecordingsCanonicalActionAdmission { currentSessions }
        let capturedAction = {
            admission.perform(sessionID: original.id) { invokedIDs.append($0.id) }
        }

        XCTAssertTrue(capturedAction())
        currentSessions = []
        XCTAssertFalse(capturedAction())
        XCTAssertEqual(invokedIDs, [original.id])
    }

    func testCapturedActionRejectsSameNameReplacementWithDifferentID() {
        let original = makeSession(title: "Shared title")
        let replacement = makeSession(title: "Shared title")
        var currentSessions = [original]
        var writes = 0
        let admission = RecordingsCanonicalActionAdmission { currentSessions }

        currentSessions = [replacement]
        XCTAssertFalse(admission.perform(sessionID: original.id) { _ in writes += 1 })
        XCTAssertEqual(writes, 0)
    }

    private func makeSession(title: String) -> RecordingSession {
        let folder = URL(fileURLWithPath: "/tmp/recordings-route-\(UUID().uuidString)")
        return RecordingSession(id: folder, folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .now, duration: 60, fileSize: 1_024,
            metadata: .init(title: title))
    }
}
