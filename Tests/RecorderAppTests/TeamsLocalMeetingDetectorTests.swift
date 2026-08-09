import CoreGraphics
import XCTest
@testable import RecorderApp

final class TeamsLocalMeetingDetectorTests: XCTestCase {
    func testSameReadyWindowRequiresThreeObservationsBeforeEntry() {
        var detector = TeamsLocalMeetingDetector(confirmObservations: 3, endObservations: 30)

        XCTAssertNil(detector.observe(.resolved(.ready(match(id: 7)))).meetingTransition)
        XCTAssertNil(detector.observe(.resolved(.ready(match(id: 7)))).meetingTransition)
        XCTAssertEqual(
            detector.observe(.resolved(.ready(match(id: 7)))).meetingTransition,
            true
        )
    }

    func testIdentityChangeRestartsConfirmation() {
        var detector = TeamsLocalMeetingDetector(confirmObservations: 3, endObservations: 30)
        _ = detector.observe(.resolved(.ready(match(id: 7))))
        _ = detector.observe(.resolved(.ready(match(id: 7))))

        XCTAssertNil(detector.observe(.resolved(.ready(match(id: 8)))).meetingTransition)
        XCTAssertEqual(detector.state, .confirming(secondsRemaining: 2))
    }

    func testUnknownAndAmbiguousDoNotEndDetectedMeeting() {
        var detector = detectedDetector()

        XCTAssertNil(detector.observe(.unknown).meetingTransition)
        XCTAssertNil(detector.observe(.resolved(.ambiguous([]))).meetingTransition)
        XCTAssertEqual(detector.state, .detected(.high))
    }

    func testThirtyMissingObservationsEmitOneExit() {
        var detector = detectedDetector(endObservations: 30)

        for _ in 0..<29 {
            XCTAssertNil(detector.observe(.resolved(.waiting)).meetingTransition)
        }
        XCTAssertEqual(detector.observe(.resolved(.waiting)).meetingTransition, false)
        XCTAssertNil(detector.observe(.resolved(.waiting)).meetingTransition)
    }

    func testResetReturnsToWaitingWithoutEmittingTransition() {
        var detector = detectedDetector()

        let update = detector.reset()

        XCTAssertEqual(update.state, .waiting)
        XCTAssertNil(update.meetingTransition)
    }

    private func detectedDetector(endObservations: Int = 30) -> TeamsLocalMeetingDetector {
        var detector = TeamsLocalMeetingDetector(confirmObservations: 1, endObservations: endObservations)
        _ = detector.observe(.resolved(.ready(match(id: 7))))
        return detector
    }

    private func match(id: CGWindowID) -> TeamsWindowMatch {
        TeamsWindowMatch(
            window: TeamsWindowDescriptor(
                identity: TeamsWindowIdentity(processID: 42, windowID: id),
                title: "Meeting",
                frame: CGRect(x: 0, y: 0, width: 1_280, height: 720),
                isOnScreen: true,
                layer: 0,
                firstSeenAt: .distantPast,
                lastSurfacedAt: .distantPast
            ),
            confidence: .high
        )
    }
}
