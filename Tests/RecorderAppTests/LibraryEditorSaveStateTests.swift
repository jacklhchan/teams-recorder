import XCTest
@testable import RecorderApp

@MainActor
final class LibraryEditorSaveStateTests: XCTestCase {
    func testFirstSubmitEntersSavingAndDuplicateIsIgnored() {
        let state = LibraryEditorSaveState()
        let sessionID = editorSessionID("first-submit")

        let first = state.begin(sessionID: sessionID, artifact: .transcript)
        let duplicate = state.begin(sessionID: sessionID, artifact: .transcript)

        XCTAssertNotNil(first)
        XCTAssertNil(duplicate)
        XCTAssertEqual(state.state, .saving)
    }

    func testMatchingFailureKeepsEditorOpenAndExposesExactFailure() {
        let state = LibraryEditorSaveState()
        let sessionID = editorSessionID("failure")
        let attempt = try! XCTUnwrap(state.begin(sessionID: sessionID, artifact: .transcript))
        let failure = LibrarySaveFailure(artifact: .transcript, userMessage: "Disk write failed")

        let disposition = state.complete(
            attempt,
            outcome: .init(sessionID: sessionID, savedArtifacts: [], failures: [failure])
        )

        XCTAssertEqual(disposition, .keepOpen)
        XCTAssertEqual(state.state, .failed(failure))
        XCTAssertFalse(state.didDismiss)
    }

    func testCurrentAttemptWithMismatchedOutcomeLeavesSavingWithoutDismissing() {
        let state = LibraryEditorSaveState()
        let sessionID = editorSessionID("expected")
        let otherID = editorSessionID("other")
        let attempt = try! XCTUnwrap(state.begin(sessionID: sessionID, artifact: .metadata))

        XCTAssertEqual(state.complete(attempt, outcome: .saved(sessionID: otherID, .metadata)), .keepOpen)
        XCTAssertEqual(state.state, .idle)
        XCTAssertFalse(state.didDismiss)

        let nextAttempt = try! XCTUnwrap(state.begin(sessionID: sessionID, artifact: .metadata))
        XCTAssertEqual(state.complete(nextAttempt, outcome: .saved(sessionID: sessionID, .transcript)), .keepOpen)
        XCTAssertEqual(state.state, .idle)
        XCTAssertFalse(state.didDismiss)
    }

    func testStaleAttemptCompletionDoesNotAffectCurrentAttempt() {
        let state = LibraryEditorSaveState()
        let sessionID = editorSessionID("expected")
        let attempt = try! XCTUnwrap(state.begin(sessionID: sessionID, artifact: .metadata))
        let staleAttempt = LibraryEditorSaveAttempt(
            episode: attempt.episode,
            identifier: UUID(),
            sessionID: sessionID,
            artifact: .metadata
        )

        XCTAssertEqual(state.complete(staleAttempt, outcome: .saved(sessionID: sessionID, .metadata)), .keepOpen)
        XCTAssertEqual(state.state, .saving)
        XCTAssertFalse(state.didDismiss)
    }

    func testMatchingFailureWinsOverMatchingSavedArtifact() {
        let state = LibraryEditorSaveState()
        let sessionID = editorSessionID("failure-wins")
        let attempt = try! XCTUnwrap(state.begin(sessionID: sessionID, artifact: .transcript))
        let failure = LibrarySaveFailure(artifact: .transcript, userMessage: "Metadata conflict")

        XCTAssertEqual(
            state.complete(
                attempt,
                outcome: .init(sessionID: sessionID, savedArtifacts: [.transcript], failures: [failure])
            ),
            .keepOpen
        )
        XCTAssertEqual(state.state, .failed(failure))
        XCTAssertFalse(state.didDismiss)
    }

    func testInvalidationRejectsOldEpisodeCompletion() {
        let state = LibraryEditorSaveState()
        let sessionID = editorSessionID("episode")
        let oldAttempt = try! XCTUnwrap(state.begin(sessionID: sessionID, artifact: .transcript))

        state.invalidate()
        let newAttempt = try! XCTUnwrap(state.begin(sessionID: sessionID, artifact: .transcript))

        XCTAssertEqual(state.complete(oldAttempt, outcome: .saved(sessionID: sessionID, .transcript)), .keepOpen)
        XCTAssertEqual(state.state, .saving)
        XCTAssertEqual(state.complete(newAttempt, outcome: .saved(sessionID: sessionID, .transcript)), .dismiss)
    }

    func testCloseAndReopenInvalidationAdmitsANewSaveAfterPriorDismissal() {
        let state = LibraryEditorSaveState()
        let sessionID = editorSessionID("reopen")
        let first = try! XCTUnwrap(state.begin(sessionID: sessionID, artifact: .metadata))
        XCTAssertEqual(state.complete(first, outcome: .saved(sessionID: sessionID, .metadata)), .dismiss)
        XCTAssertTrue(state.didDismiss)

        state.invalidate()

        XCTAssertFalse(state.didDismiss)
        XCTAssertNotNil(state.begin(sessionID: sessionID, artifact: .metadata))
    }

    func testMatchingSuccessDismissesExactlyOnce() {
        let state = LibraryEditorSaveState()
        let sessionID = editorSessionID("success")
        let attempt = try! XCTUnwrap(state.begin(sessionID: sessionID, artifact: .metadata))
        let outcome = LibrarySaveOutcome.saved(sessionID: sessionID, .metadata)

        XCTAssertEqual(state.complete(attempt, outcome: outcome), .dismiss)
        XCTAssertEqual(state.complete(attempt, outcome: outcome), .keepOpen)
        XCTAssertTrue(state.didDismiss)
        XCTAssertNil(state.begin(sessionID: sessionID, artifact: .metadata))
    }

    private func editorSessionID(_ name: String) -> RecordingSession.ID {
        URL(fileURLWithPath: "/tmp/editor-save-state-\(name)-\(UUID().uuidString)")
    }
}
