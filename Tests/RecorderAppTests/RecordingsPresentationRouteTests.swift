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

    func testLocationActionsRouteOpenFolderAndRevealToDistinctCanonicalClosures() {
        let folder = URL(fileURLWithPath: "/tmp/recordings-route-\(UUID().uuidString)")
        let captured = RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("stale-recording.m4a"),
            createdAt: .distantPast,
            duration: 1,
            fileSize: 1,
            metadata: .init(title: "Captured")
        )
        let canonical = RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 60,
            fileSize: 1_024,
            metadata: .init(title: "Canonical")
        )
        var openedFolders: [URL] = []
        var revealedRecordings: [URL] = []
        let actions = RecordingsSessionLocationActions(
            currentSessions: { [canonical] },
            openFolder: { openedFolders.append($0.folderURL) },
            revealRecording: { revealedRecordings.append($0.recordingURL) }
        )

        XCTAssertTrue(actions.perform(.revealRecording, sessionID: captured.id))
        XCTAssertEqual(revealedRecordings, [canonical.recordingURL])
        XCTAssertTrue(openedFolders.isEmpty)

        XCTAssertTrue(actions.perform(.openFolder, sessionID: captured.id))
        XCTAssertEqual(openedFolders, [canonical.folderURL])
        XCTAssertEqual(revealedRecordings, [canonical.recordingURL])
    }

    func testSaveRejectsMissingCanonicalSessionWithoutInvokingWrite() async {
        let original = makeSession(title: "Original")
        var currentSessions = [original]
        let admission = RecordingsCanonicalActionAdmission { currentSessions }
        currentSessions = []
        var writes = 0

        let outcome = await admission.save(
            sessionID: original.id,
            artifact: .transcript
        ) { _ in
            writes += 1
            return .saved(sessionID: original.id, .transcript)
        }

        XCTAssertEqual(writes, 0)
        XCTAssertEqual(
            outcome,
            .failed(
                sessionID: original.id,
                .transcript,
                "The recording is no longer available."
            )
        )
    }

    func testPerformAsyncRejectsReplacementCanonicalSessionWithoutInvokingAction() async {
        let original = makeSession(title: "Shared title")
        let replacement = makeSession(title: "Shared title")
        var currentSessions = [original]
        let admission = RecordingsCanonicalActionAdmission { currentSessions }
        currentSessions = [replacement]
        var invoked = false

        let admitted = await admission.performAsync(sessionID: original.id) { _ in
            invoked = true
        }

        XCTAssertFalse(admitted)
        XCTAssertFalse(invoked)
    }

    private func makeSession(title: String) -> RecordingSession {
        let folder = URL(fileURLWithPath: "/tmp/recordings-route-\(UUID().uuidString)")
        return RecordingSession(id: folder, folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .now, duration: 60, fileSize: 1_024,
            metadata: .init(title: title))
    }
}
