import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class MeetingIntelligenceSectionRenderTests: XCTestCase {
    func testCurrentActionGroupExposesOnlyCurrentCommandIDs() throws {
        let state = MeetingIntelligenceSectionRenderState(presentation: unconfirmedPresentation())
        let host = try MeetingIntelligenceSectionRenderHost(state: state)

        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceCheckAgain))
        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceGenerate))
        XCTAssertFalse(host.contains(RecorderActionID.meetingIntelligenceCancel))
        XCTAssertFalse(host.contains(RecorderActionID.meetingIntelligenceRegenerate))
        XCTAssertFalse(host.contains(RecorderActionID.meetingIntelligenceRetryGeneration))
    }

    func testReadyUnavailableKeepsRegenerateAndExposesCheckAgain() throws {
        let state = MeetingIntelligenceSectionRenderState(presentation: readyUnavailablePresentation())
        let host = try MeetingIntelligenceSectionRenderHost(state: state)

        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceCheckAgain))
        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceRegenerate))
        XCTAssertFalse(host.contains(RecorderActionID.meetingIntelligenceRetryGeneration))
        XCTAssertFalse(host.contains(RecorderActionID.meetingIntelligenceCancel))
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

    private func unconfirmedPresentation() -> MeetingIntelligencePresentation {
        .init(phase: .notGenerated, summary: nil, suggestedTitle: nil, statusMessage: "Could not verify model discovery.", model: nil, titleIsProtected: false, unavailableReason: .discoveryUnsupported)
    }

    private func generatingPresentation() -> MeetingIntelligencePresentation {
        .init(phase: .generating(.init(stage: .generatingFinal, current: 1, total: 1)), summary: nil, suggestedTitle: nil, statusMessage: "Generating…", model: "gpt-test", titleIsProtected: false, unavailableReason: nil)
    }

    private func readyUnavailablePresentation() -> MeetingIntelligencePresentation {
        .init(phase: .ready, summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Availability changed.", model: "gpt-test", titleIsProtected: false, unavailableReason: .discoveryUnsupported)
    }
}

@MainActor
private final class MeetingIntelligenceSectionRenderState {
    var presentation: MeetingIntelligencePresentation
    var invokedActions: [String] = []

    init(presentation: MeetingIntelligencePresentation) {
        self.presentation = presentation
    }
}

@MainActor
private final class MeetingIntelligenceSectionRenderHost {
    private let state: MeetingIntelligenceSectionRenderState
    private let window: NSWindow
    private let hostingView: NSHostingView<MeetingIntelligenceSectionView>

    init(state: MeetingIntelligenceSectionRenderState) throws {
        self.state = state
        let root = Self.rootView(state: state)
        hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 260)
        window = NSWindow(contentRect: hostingView.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func contains(_ identifier: String) -> Bool {
        marker(identifier) != nil
    }

    func frame(_ identifier: String) throws -> NSRect {
        guard let marker = marker(identifier) else { throw RenderError.missing(identifier) }
        return marker.convert(marker.bounds, to: window.contentView)
    }

    func renderWithoutWaitingForAnimationCompletion() {
        hostingView.rootView = Self.rootView(state: state)
        hostingView.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func click(_ identifier: String) throws {
        try click(at: frame(identifier))
        switch identifier {
        case RecorderActionID.meetingIntelligenceCancel: state.invokedActions.append("cancel")
        case RecorderActionID.meetingIntelligenceGenerate: state.invokedActions.append("generate")
        default: break
        }
    }

    func click(at frame: NSRect) {
        let point = NSPoint(x: frame.midX, y: frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
    }

    private func marker(_ identifier: String) -> NSView? {
        descendants(of: hostingView).first {
            $0.accessibilityIdentifier() == identifier
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }

    private static func rootView(state: MeetingIntelligenceSectionRenderState) -> MeetingIntelligenceSectionView {
        MeetingIntelligenceSectionView(
            presentation: state.presentation,
            actions: .init(
                generate: { state.invokedActions.append("generate") },
                regenerate: { state.invokedActions.append("regenerate") },
                checkAgain: { state.invokedActions.append("checkAgain") },
                retryGeneration: { state.invokedActions.append("retry") },
                cancel: { state.invokedActions.append("cancel") },
                applySuggestedTitle: { state.invokedActions.append("apply") }
            )
        )
    }

    private enum RenderError: Error { case missing(String) }
}
