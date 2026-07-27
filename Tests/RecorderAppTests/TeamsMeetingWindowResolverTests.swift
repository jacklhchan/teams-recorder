import CoreGraphics
import XCTest
@testable import RecorderApp

final class TeamsMeetingWindowResolverTests: XCTestCase {
    private let beforeMeeting = Date(timeIntervalSinceReferenceDate: 1_000)
    private let meetingStarted = Date(timeIntervalSinceReferenceDate: 1_100)

    func testRejectsNonTeamsUtilitySizedAndNonNormalLayerWindows() {
        XCTAssertEqual(TeamsMeetingWindowResolver.rejectionReasons(for: snapshot(title: "Settings")), [.utilityTitle])
        XCTAssertEqual(TeamsMeetingWindowResolver.rejectionReasons(for: snapshot(title: "Notification")), [.utilityTitle])
        XCTAssertEqual(TeamsMeetingWindowResolver.rejectionReasons(for: snapshot(title: "Microsoft Teams Helper")), [.utilityTitle])
        XCTAssertEqual(TeamsMeetingWindowResolver.rejectionReasons(for: snapshot(layer: 1)), [.nonNormalLayer])
        XCTAssertEqual(TeamsMeetingWindowResolver.rejectionReasons(for: snapshot(width: 639)), [.insufficientWidth])
        XCTAssertEqual(TeamsMeetingWindowResolver.rejectionReasons(for: snapshot(height: 359)), [.insufficientHeight])
        XCTAssertEqual(
            TeamsMeetingWindowResolver.rejectionReasons(for: snapshot(width: 640, height: 359)),
            [.insufficientHeight, .insufficientArea]
        )
        XCTAssertEqual(TeamsMeetingWindowResolver.rejectionReasons(for: snapshot()), [])
    }

    func testRetainsCurrentWindowAcrossResizeAndOcclusion() {
        var resolver = TeamsMeetingWindowResolver()
        let identity = TeamsWindowIdentity(processID: 7, windowID: 10)

        assertReady(resolver.observe([snapshot(identity: identity, width: 1_280, height: 720)], meetingActive: true, now: meetingStarted), identity: identity)
        assertReady(resolver.observe([snapshot(identity: identity, width: 800, height: 600)], meetingActive: true, now: meetingStarted.addingTimeInterval(1)), identity: identity)
        XCTAssertEqual(
            resolver.observe([snapshot(identity: identity, isOnScreen: false)], meetingActive: true, now: meetingStarted.addingTimeInterval(2)),
            .waiting
        )
        assertReady(resolver.observe([snapshot(identity: identity, width: 1_024, height: 768)], meetingActive: true, now: meetingStarted.addingTimeInterval(3)), identity: identity)
    }

    func testManualOverrideReplacesCurrentWindow() {
        var resolver = TeamsMeetingWindowResolver()
        let first = TeamsWindowIdentity(processID: 7, windowID: 10)
        let manual = TeamsWindowIdentity(processID: 7, windowID: 11)

        _ = resolver.observe([snapshot(identity: first), snapshot(identity: manual, width: 1_000, height: 700)], meetingActive: true, now: meetingStarted)
        resolver.selectManualOverride(manual)

        assertReady(resolver.observe([snapshot(identity: first), snapshot(identity: manual, width: 1_000, height: 700)], meetingActive: true, now: meetingStarted.addingTimeInterval(1)), identity: manual)
    }

    func testPrefersWindowFirstSeenAfterMeetingBegan() {
        var resolver = TeamsMeetingWindowResolver()
        let existing = TeamsWindowIdentity(processID: 7, windowID: 10)
        let newMeetingWindow = TeamsWindowIdentity(processID: 7, windowID: 11)

        _ = resolver.observe([snapshot(identity: existing, width: 1_600, height: 900)], meetingActive: false, now: beforeMeeting)

        assertReady(resolver.observe([snapshot(identity: existing, width: 1_600, height: 900), snapshot(identity: newMeetingWindow, width: 1_000, height: 700)], meetingActive: true, now: meetingStarted), identity: newMeetingWindow)
    }

    func testPrefersWindowSurfacedAfterMeetingBegan() {
        var resolver = TeamsMeetingWindowResolver()
        let existing = TeamsWindowIdentity(processID: 7, windowID: 10)
        let surfacedDuringMeeting = TeamsWindowIdentity(processID: 7, windowID: 11)

        _ = resolver.observe([snapshot(identity: existing, width: 1_600, height: 900), snapshot(identity: surfacedDuringMeeting, isOnScreen: false)], meetingActive: false, now: beforeMeeting)

        assertReady(resolver.observe([snapshot(identity: existing, width: 1_600, height: 900), snapshot(identity: surfacedDuringMeeting, width: 1_000, height: 700)], meetingActive: true, now: meetingStarted), identity: surfacedDuringMeeting)
    }

    func testSelectsLargestHighConfidenceOnScreenCandidate() {
        var resolver = TeamsMeetingWindowResolver()
        let smaller = TeamsWindowIdentity(processID: 7, windowID: 10)
        let larger = TeamsWindowIdentity(processID: 7, windowID: 11)

        let result = resolver.observe([snapshot(identity: smaller, width: 1_000, height: 700), snapshot(identity: larger, width: 1_400, height: 900)], meetingActive: true, now: meetingStarted)

        assertReady(result, identity: larger)
    }

    func testSimilarCandidatesFailClosedAsAmbiguous() {
        var resolver = TeamsMeetingWindowResolver()
        let first = TeamsWindowIdentity(processID: 7, windowID: 10)
        let second = TeamsWindowIdentity(processID: 7, windowID: 11)

        let result = resolver.observe([snapshot(identity: first, width: 1_000, height: 800), snapshot(identity: second, width: 960, height: 800)], meetingActive: true, now: meetingStarted)

        guard case .ambiguous(let candidates) = result else {
            return XCTFail("Expected an ambiguous resolution")
        }
        XCTAssertEqual(candidates.map(\.identity), [first, second])
    }

    func testOwnerPIDPreventsReusedWindowIDFromInheritingPreMeetingState() {
        var resolver = TeamsMeetingWindowResolver()
        let oldIdentity = TeamsWindowIdentity(processID: 7, windowID: 10)
        let reusedWindowID = TeamsWindowIdentity(processID: 8, windowID: 10)

        XCTAssertEqual(
            resolver.observe([snapshot(identity: oldIdentity)], meetingActive: false, now: beforeMeeting),
            .waiting
        )
        assertReady(
            resolver.observe([snapshot(identity: reusedWindowID)], meetingActive: true, now: meetingStarted),
            identity: reusedWindowID,
            confidence: .high
        )
    }

    func testMinimizedCurrentWindowRemainsIdentifiedButIsNotCaptureReady() {
        var resolver = TeamsMeetingWindowResolver()
        let identity = TeamsWindowIdentity(processID: 7, windowID: 10)

        assertReady(resolver.observe([snapshot(identity: identity)], meetingActive: true, now: meetingStarted), identity: identity)
        XCTAssertEqual(
            resolver.observe([snapshot(identity: identity, isOnScreen: false)], meetingActive: true, now: meetingStarted.addingTimeInterval(1)),
            .waiting
        )
        assertReady(resolver.observe([snapshot(identity: identity)], meetingActive: true, now: meetingStarted.addingTimeInterval(2)), identity: identity)
    }

    private func assertReady(
        _ resolution: TeamsWindowResolution,
        identity: TeamsWindowIdentity,
        confidence: TeamsWindowConfidence = .high
    ) {
        guard case .ready(let match) = resolution else {
            return XCTFail("Expected a ready resolution, got \\(resolution)")
        }
        XCTAssertEqual(match.window.identity, identity)
        XCTAssertEqual(match.confidence, confidence)
    }

    private func snapshot(
        identity: TeamsWindowIdentity = .init(processID: 7, windowID: 10),
        title: String = "Meeting",
        width: CGFloat = 1_280,
        height: CGFloat = 720,
        isOnScreen: Bool = true,
        layer: Int = 0
    ) -> TeamsWindowSnapshot {
        .init(identity: identity, title: title, frame: CGRect(x: 0, y: 0, width: width, height: height), isOnScreen: isOnScreen, layer: layer)
    }
}
