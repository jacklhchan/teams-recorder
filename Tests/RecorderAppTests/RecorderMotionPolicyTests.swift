import XCTest
@testable import RecorderApp

final class RecorderMotionPolicyTests: XCTestCase {
    func testNormalPolicyUsesApprovedRestrainedMotion() {
        let policy = RecorderMotionPolicy.make(reduceMotion: false)
        XCTAssertEqual(policy.pressedScale, 0.975)
        XCTAssertEqual(policy.pressDuration, 0.08)
        XCTAssertEqual(policy.releaseDuration, 0.18)
        XCTAssertEqual(policy.statusDuration, 0.18)
        XCTAssertEqual(policy.revealDuration, 0.26)
        XCTAssertEqual(policy.revealOffset, 6)
        XCTAssertTrue(policy.drawsCompletionStroke)
        XCTAssertTrue(policy.travelsIndeterminateSegment)
    }

    func testReduceMotionRemovesMovementPulseStrokeAndContinuousTravel() {
        let policy = RecorderMotionPolicy.make(reduceMotion: true)
        XCTAssertEqual(policy.pressedScale, 1)
        XCTAssertEqual(policy.pressDuration, 0)
        XCTAssertEqual(policy.releaseDuration, 0)
        XCTAssertEqual(policy.statusDuration, 0.16)
        XCTAssertEqual(policy.revealDuration, 0.16)
        XCTAssertEqual(policy.revealOffset, 0)
        XCTAssertFalse(policy.drawsCompletionStroke)
        XCTAssertFalse(policy.travelsIndeterminateSegment)
    }

    func testVisibleReadyEdgeEmitsOnceButInitialReadyAndRerenderDoNot() {
        let working = snapshot(
            revision: 1,
            phase: .working,
            title: "Initial title"
        )
        let ready = snapshot(
            revision: 2,
            phase: .ready,
            title: "Generated title"
        )
        XCTAssertEqual(.none, RecorderObservedTransition.feedback(previous: nil, current: ready))
        XCTAssertEqual(.init(completed: true, generatedTitleChanged: false), RecorderObservedTransition.feedback(previous: working, current: ready))
        XCTAssertEqual(.none, RecorderObservedTransition.feedback(previous: ready, current: ready))
    }

    func testSessionChangeAndManualTitleOwnershipSuppressFeedback() {
        let previous = snapshot(revision: 7, phase: .working, sessionID: "A", title: "Old")
        let otherSession = snapshot(revision: 8, phase: .ready, sessionID: "B", title: "Generated")
        let protected = snapshot(revision: 8, phase: .ready, sessionID: "A", title: "Manual", protected: true)
        XCTAssertEqual(.none, RecorderObservedTransition.feedback(previous: previous, current: otherSession))
        XCTAssertEqual(.init(completed: true, generatedTitleChanged: false), RecorderObservedTransition.feedback(previous: previous, current: protected))
    }

    func testGeneratedTitleFeedbackRequiresNewerReadyToReadySnapshotAndUnprotectedTitle() {
        let previous = snapshot(revision: 11, phase: .ready, title: "Old")
        let current = snapshot(revision: 12, phase: .ready, title: "Generated")
        XCTAssertEqual(.init(completed: false, generatedTitleChanged: true), RecorderObservedTransition.feedback(previous: previous, current: current))
    }

    private func snapshot(
        revision: UInt64,
        phase: RecorderObservedPhase,
        sessionID: String = "session",
        title: String = "Title",
        protected: Bool = false
    ) -> RecorderObservedSnapshot {
        .init(
            featureRevision: revision,
            identity: identity(for: sessionID),
            phase: phase,
            displayedTitle: title,
            titleIsProtected: protected
        )
    }

    private func identity(for sessionID: String) -> MeetingIntelligenceSessionPresentationIdentity {
        let folder = URL(fileURLWithPath: "/tmp/recorder-observed-\(sessionID)")
        let session = RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .distantPast,
            duration: 0,
            fileSize: 0,
            metadata: .init()
        )
        return MeetingIntelligenceSessionPresentationIdentity(session: session)!
    }
}
