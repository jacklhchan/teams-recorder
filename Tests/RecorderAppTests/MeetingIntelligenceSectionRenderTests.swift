import AppKit
import Combine
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class MeetingIntelligenceSectionRenderTests: XCTestCase {
    func testPhaseMatrixExposesOnlyCurrentCommands() throws {
        try assertCommands(unconfirmedPresentation(), present: [RecorderActionID.meetingIntelligenceCheckAgain, RecorderActionID.meetingIntelligenceGenerate])
        try assertCommands(checkingPresentation(), present: [RecorderActionID.meetingIntelligenceCancel])
        try assertCommands(generatingPresentation(), present: [RecorderActionID.meetingIntelligenceCancel])
        try assertCommands(readyPresentation(), present: [RecorderActionID.meetingIntelligenceRegenerate])
        try assertCommands(stalePresentation(), present: [RecorderActionID.meetingIntelligenceRegenerate])
        try assertCommands(readyUnavailablePresentation(), present: [RecorderActionID.meetingIntelligenceCheckAgain, RecorderActionID.meetingIntelligenceRegenerate])
        try assertCommands(protectedReadyPresentation(), present: [RecorderActionID.meetingIntelligenceRegenerate, RecorderActionID.meetingIntelligenceApplyTitle])
        try assertCommands(recoveryPresentation(.failed), present: [RecorderActionID.meetingIntelligenceRetryGeneration])
        try assertCommands(recoveryPresentation(.cancelled), present: [RecorderActionID.meetingIntelligenceRetryGeneration])
        try assertCommands(recoveryPresentation(.interrupted), present: [RecorderActionID.meetingIntelligenceRetryGeneration])
        try assertCommands(recoveryPresentation(.failed, unavailable: true), present: [RecorderActionID.meetingIntelligenceCheckAgain, RecorderActionID.meetingIntelligenceRetryGeneration])
        try assertCommands(recoveryPresentation(.cancelled, unavailable: true), present: [RecorderActionID.meetingIntelligenceCheckAgain, RecorderActionID.meetingIntelligenceRetryGeneration])
        try assertCommands(recoveryPresentation(.interrupted, unavailable: true), present: [RecorderActionID.meetingIntelligenceCheckAgain, RecorderActionID.meetingIntelligenceRetryGeneration])
        try assertCommands(recoveryPresentation(.failed, unavailable: true, protected: true), present: [RecorderActionID.meetingIntelligenceCheckAgain, RecorderActionID.meetingIntelligenceRetryGeneration, RecorderActionID.meetingIntelligenceApplyTitle])
    }

    func testOutgoingGenerateIsImmediatelyStaleAndIncomingCancelIsImmediatelyRoutable() throws {
        let state = MeetingIntelligenceSectionRenderState(presentation: unconfirmedPresentation())
        let host = try MeetingIntelligenceSectionRenderHost(state: state)
        let outgoingGenerateFrame = try host.frame(RecorderActionID.meetingIntelligenceGenerate)

        state.presentation = generatingPresentation()
        host.renderWithoutWaitingForAnimationCompletion()
        host.click(at: outgoingGenerateFrame)
        XCTAssertFalse(state.invokedActions.contains("generate"))
        try host.click(RecorderActionID.meetingIntelligenceCancel)
        XCTAssertEqual(state.invokedActions.filter { $0 == "cancel" }.count, 1)
    }

    func testInitialReadyObservedSnapshotIsStatic() throws {
        let state = MeetingIntelligenceSectionRenderState(
            presentation: readyPresentation(),
            observedSnapshot: snapshot(1, phase: .ready, title: "Initial title")
        )
        let host = try MeetingIntelligenceSectionRenderHost(state: state)

        XCTAssertFalse(host.contains("meeting-intelligence.feedback.completion"))
        XCTAssertFalse(host.contains("meeting-intelligence.feedback.generated-title"))
    }

    func testWorkingToReadyObservedSnapshotShowsCompletionFeedback() throws {
        let state = MeetingIntelligenceSectionRenderState(
            presentation: generatingPresentation(),
            observedSnapshot: snapshot(1, phase: .working, title: "Initial title")
        )
        let host = try MeetingIntelligenceSectionRenderHost(state: state)

        state.presentation = readyPresentation()
        state.observedSnapshot = snapshot(2, phase: .ready, title: "Generated title")
        host.renderWithoutWaitingForAnimationCompletion()

        XCTAssertTrue(host.contains("meeting-intelligence.feedback.completion"))
    }

    func testNewerReadyTitleChangeShowsGeneratedTitleHighlight() throws {
        let state = MeetingIntelligenceSectionRenderState(
            presentation: readyPresentation(),
            observedSnapshot: snapshot(2, phase: .ready, title: "Generated title")
        )
        let host = try MeetingIntelligenceSectionRenderHost(state: state)

        state.observedSnapshot = snapshot(3, phase: .ready, title: "Updated title")
        host.renderWithoutWaitingForAnimationCompletion()

        XCTAssertTrue(host.contains("meeting-intelligence.feedback.generated-title"))
        XCTAssertFalse(host.contains("meeting-intelligence.feedback.completion"))
    }

    func testProtectedReadyTitleChangeSuppressesObservedFeedback() throws {
        let state = MeetingIntelligenceSectionRenderState(
            presentation: protectedReadyPresentation(),
            observedSnapshot: snapshot(2, phase: .ready, title: "Generated title")
        )
        let host = try MeetingIntelligenceSectionRenderHost(state: state)

        state.observedSnapshot = snapshot(3, phase: .ready, title: "Manual title", protected: true)
        host.renderWithoutWaitingForAnimationCompletion()

        XCTAssertFalse(host.contains("meeting-intelligence.feedback.completion"))
        XCTAssertFalse(host.contains("meeting-intelligence.feedback.generated-title"))
    }

    func testCrossSessionAndNonNewerObservedSnapshotsSuppressFeedback() throws {
        let state = MeetingIntelligenceSectionRenderState(
            presentation: readyPresentation(),
            observedSnapshot: snapshot(3, phase: .ready, title: "Current title")
        )
        let host = try MeetingIntelligenceSectionRenderHost(state: state)

        state.observedSnapshot = snapshot(4, sessionID: "session-2", phase: .ready, title: "Other session")
        host.renderWithoutWaitingForAnimationCompletion()
        XCTAssertFalse(host.contains("meeting-intelligence.feedback.completion"))
        XCTAssertFalse(host.contains("meeting-intelligence.feedback.generated-title"))

        state.observedSnapshot = snapshot(3, sessionID: "session-2", phase: .ready, title: "Stale revision")
        host.renderWithoutWaitingForAnimationCompletion()
        XCTAssertFalse(host.contains("meeting-intelligence.feedback.completion"))
        XCTAssertFalse(host.contains("meeting-intelligence.feedback.generated-title"))

        state.observedSnapshot = snapshot(3, sessionID: "session-2", phase: .ready, title: "Same revision")
        host.renderWithoutWaitingForAnimationCompletion()
        XCTAssertFalse(host.contains("meeting-intelligence.feedback.completion"))
        XCTAssertFalse(host.contains("meeting-intelligence.feedback.generated-title"))
    }

    func testReduceMotionKeepsCompletionFeedbackAccessibleWithoutTravellingMotion() throws {
        let state = MeetingIntelligenceSectionRenderState(
            presentation: generatingPresentation(),
            observedSnapshot: snapshot(1, phase: .working, title: "Initial title")
        )
        let host = try MeetingIntelligenceSectionRenderHost(state: state, reduceMotion: true)

        state.presentation = readyPresentation()
        state.observedSnapshot = snapshot(2, phase: .ready, title: "Generated title")
        host.renderWithoutWaitingForAnimationCompletion()

        XCTAssertTrue(host.contains("meeting-intelligence.feedback.completion"))
        XCTAssertTrue(host.contains("meeting-intelligence.feedback.completion.static"))
        XCTAssertFalse(host.contains("meeting-intelligence.feedback.completion.draw-on"))
    }

    private func assertCommands(_ presentation: MeetingIntelligencePresentation, present: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let host = try MeetingIntelligenceSectionRenderHost(state: .init(presentation: presentation))
        let all = [
            RecorderActionID.meetingIntelligenceCheckAgain,
            RecorderActionID.meetingIntelligenceGenerate,
            RecorderActionID.meetingIntelligenceCancel,
            RecorderActionID.meetingIntelligenceRegenerate,
            RecorderActionID.meetingIntelligenceRetryGeneration,
            RecorderActionID.meetingIntelligenceApplyTitle
        ]
        for identifier in all {
            XCTAssertEqual(host.contains(identifier), present.contains(identifier), "unexpected command visibility: \(identifier)", file: file, line: line)
        }
    }

    private func unconfirmedPresentation() -> MeetingIntelligencePresentation {
        .init(phase: .notGenerated, summary: nil, suggestedTitle: nil, statusMessage: "Could not verify model discovery.", model: nil, titleIsProtected: false, unavailableReason: .discoveryUnsupported)
    }

    private func checkingPresentation() -> MeetingIntelligencePresentation {
        .init(phase: .checkingAvailability, summary: nil, suggestedTitle: nil, statusMessage: "Checking…", model: nil, titleIsProtected: false, unavailableReason: nil)
    }

    private func generatingPresentation() -> MeetingIntelligencePresentation {
        .init(phase: .generating(.init(stage: .generatingFinal, current: 1, total: 1)), summary: "Existing summary", suggestedTitle: "Existing title", statusMessage: "Generating…", model: "gpt-test", titleIsProtected: false, unavailableReason: nil)
    }

    private func readyPresentation() -> MeetingIntelligencePresentation {
        .init(phase: .ready, summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Ready.", model: "gpt-test", titleIsProtected: false, unavailableReason: nil)
    }

    private func readyUnavailablePresentation() -> MeetingIntelligencePresentation {
        .init(phase: .ready, summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Availability changed.", model: "gpt-test", titleIsProtected: false, unavailableReason: .discoveryUnsupported)
    }

    private func stalePresentation() -> MeetingIntelligencePresentation {
        .init(phase: .stale, summary: "Older summary", suggestedTitle: "Older title", statusMessage: "Refresh when ready.", model: "gpt-test", titleIsProtected: false, unavailableReason: nil)
    }

    private func protectedReadyPresentation() -> MeetingIntelligencePresentation {
        .init(phase: .ready, summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Ready.", model: "gpt-test", titleIsProtected: true, unavailableReason: nil)
    }

    private func recoveryPresentation(_ phase: MeetingIntelligencePresentation.Phase, unavailable: Bool = false, protected: Bool = false) -> MeetingIntelligencePresentation {
        .init(phase: phase, summary: "Summary", suggestedTitle: protected ? "Suggested title" : nil, statusMessage: "Try again.", model: "gpt-test", titleIsProtected: protected, unavailableReason: unavailable ? .discoveryUnsupported : nil)
    }

    private func snapshot(_ revision: UInt64, sessionID: String = "session-1", phase: RecorderObservedPhase, title: String, protected: Bool = false) -> RecorderObservedSnapshot {
        .init(featureRevision: revision, sessionID: sessionID, phase: phase, displayedTitle: title, titleIsProtected: protected)
    }
}

@MainActor
private final class MeetingIntelligenceSectionRenderState: ObservableObject {
    @Published var presentation: MeetingIntelligencePresentation
    @Published var observedSnapshot: RecorderObservedSnapshot?
    var invokedActions: [String] = []

    init(presentation: MeetingIntelligencePresentation, observedSnapshot: RecorderObservedSnapshot? = nil) {
        self.presentation = presentation
        self.observedSnapshot = observedSnapshot
    }
}

private struct MeetingIntelligenceSectionRenderFixture: View {
    @ObservedObject var state: MeetingIntelligenceSectionRenderState
    let reduceMotion: Bool?

    var body: some View {
        MeetingIntelligenceSectionView(
            presentation: state.presentation,
            observedSnapshot: state.observedSnapshot,
            actions: .init(
                generate: { state.invokedActions.append("generate") },
                regenerate: { state.invokedActions.append("regenerate") },
                checkAgain: { state.invokedActions.append("checkAgain") },
                retryGeneration: { state.invokedActions.append("retry") },
                cancel: { state.invokedActions.append("cancel") },
                applySuggestedTitle: { state.invokedActions.append("apply") }
            )
        )
        .environment(\.meetingIntelligenceReduceMotionOverride, reduceMotion)
    }
}

@MainActor
private final class MeetingIntelligenceSectionRenderHost {
    private let window: NSWindow
    private let hostingView: NSHostingView<MeetingIntelligenceSectionRenderFixture>

    init(state: MeetingIntelligenceSectionRenderState, reduceMotion: Bool? = nil) throws {
        hostingView = NSHostingView(rootView: .init(state: state, reduceMotion: reduceMotion))
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 260)
        window = NSWindow(contentRect: hostingView.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func contains(_ identifier: String) -> Bool { marker(identifier) != nil }

    func accessibilityValue(for identifier: String) -> String? {
        guard let view = descendants(of: hostingView).first(where: { $0.accessibilityIdentifier() == identifier }) else {
            return nil
        }
        return view.accessibilityValue() as? String
    }

    func frame(_ identifier: String) throws -> NSRect {
        guard let marker = marker(identifier) else { throw RenderError.missing(identifier) }
        return marker.convert(marker.bounds, to: nil)
    }

    func renderWithoutWaitingForAnimationCompletion() {
        hostingView.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    func click(_ identifier: String) throws { click(at: try frame(identifier)) }

    func click(at point: NSRect) {
        let location = NSPoint(x: point.midX, y: point.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            NSApp.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    private func marker(_ identifier: String) -> NSView? {
        descendants(of: hostingView).first { $0.accessibilityIdentifier() == identifier }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }

    private enum RenderError: Error { case missing(String) }
}
