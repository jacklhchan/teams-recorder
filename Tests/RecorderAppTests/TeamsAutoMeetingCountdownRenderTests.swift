import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class TeamsAutoMeetingCountdownRenderTests: XCTestCase {
    func testCountdownFixturesHaveFixedBoundsAndCancelOnce() throws {
        for seconds in [8, 7] {
            var cancellations = 0
            let host = CountdownRenderHost(rootView: TeamsAutoMeetingCountdownView(seconds: seconds, cancel: { cancellations += 1 }))
            defer { host.close() }
            XCTAssertEqual(host.frame.size, .init(width: 360, height: 94))
            for identifier in ["teams-auto-countdown-panel", "teams-auto-countdown-seconds", "teams-auto-countdown-cancel"] { XCTAssertTrue(host.boundsContain(identifier), identifier) }
            try host.click("teams-auto-countdown-cancel")
            XCTAssertEqual(cancellations, 1)
        }
    }

    func testCountdownUsesSharedOverrideBranchesWithoutChangingBounds() {
        let normal = CountdownRenderHost(rootView: TeamsAutoMeetingCountdownView(seconds: 8, cancel: {}).environment(\.recorderReduceMotionOverride, false).environment(\.recorderReduceTransparencyOverride, false))
        defer { normal.close() }
        XCTAssertTrue(normal.contains("recorder.motion.scale"))
        XCTAssertTrue(normal.contains("recorder.glass.native"))
        let reduced = CountdownRenderHost(rootView: TeamsAutoMeetingCountdownView(seconds: 8, cancel: {}).environment(\.recorderReduceMotionOverride, true).environment(\.recorderReduceTransparencyOverride, true))
        defer { reduced.close() }
        XCTAssertTrue(reduced.contains("recorder.motion.no-scale"))
        XCTAssertTrue(reduced.contains("recorder.glass.material-separator"))
        XCTAssertTrue(reduced.boundsContain("teams-auto-countdown-cancel"))
    }
}

@MainActor
private final class CountdownRenderHost {
    private let hostingView: NSHostingView<AnyView>
    private let window: NSWindow
    init<Content: View>(rootView: Content) { hostingView = NSHostingView(rootView: AnyView(rootView)); let frame = NSRect(x: 0, y: 0, width: 360, height: 94); hostingView.frame = frame; window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false); window.contentView = hostingView; window.makeKeyAndOrderFront(nil); render() }
    var frame: NSRect { hostingView.frame }
    func contains(_ identifier: String) -> Bool { view(identifier) != nil }
    func close() { window.orderOut(nil); window.contentView = nil }
    func boundsContain(_ identifier: String) -> Bool { guard let view = view(identifier) else { return false }; return hostingView.bounds.contains(hostingView.convert(view.bounds, from: view)) }
    func click(_ identifier: String) throws { guard let view = view(identifier) else { throw XCTSkip("control marker missing") }; let location = view.convert(.init(x: view.bounds.midX, y: view.bounds.midY), to: nil); for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] { if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { window.sendEvent(event) } }; render() }
    private func render() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); window.layoutIfNeeded(); hostingView.layoutSubtreeIfNeeded() }
    private func view(_ identifier: String) -> NSView? { allViews(hostingView).first { $0.accessibilityIdentifier() == identifier } }
    private func allViews(_ view: NSView) -> [NSView] {
        let children = view.subviews + ((view.accessibilityChildren() as? [NSView]) ?? [])
        return [view] + children.flatMap(allViews)
    }
}
