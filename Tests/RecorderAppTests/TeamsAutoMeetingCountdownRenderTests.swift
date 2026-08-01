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
        let identifiers = ["teams-auto-countdown-panel", "teams-auto-countdown-seconds", "teams-auto-countdown-cancel"]
        let variants: [(Bool, Bool, String, String)] = [(false, false, "recorder.motion.scale", "recorder.glass.native"), (true, false, "recorder.motion.no-scale", "recorder.glass.native"), (false, true, "recorder.motion.scale", "recorder.glass.material-separator")]
        var baseline: [String: NSRect]?
        for (motion, transparency, expectedMotion, expectedGlass) in variants {
            let host = CountdownRenderHost(rootView: TeamsAutoMeetingCountdownView(seconds: 8, cancel: {}).environment(\.recorderReduceMotionOverride, motion).environment(\.recorderReduceTransparencyOverride, transparency))
            defer { host.close() }
            XCTAssertTrue(host.contains(expectedMotion))
            XCTAssertFalse(host.contains(expectedMotion == "recorder.motion.scale" ? "recorder.motion.no-scale" : "recorder.motion.scale"))
            XCTAssertTrue(host.contains(expectedGlass))
            XCTAssertFalse(host.contains(expectedGlass == "recorder.glass.native" ? "recorder.glass.material-separator" : "recorder.glass.native"))
            let frames = Dictionary(uniqueKeysWithValues: identifiers.compactMap { identifier in host.locationMarkerFrame(identifier).map { (identifier, $0) } })
            XCTAssertEqual(frames.count, identifiers.count)
            for identifier in identifiers { XCTAssertTrue(host.boundsContain(identifier), identifier) }
            if let baseline {
                for identifier in identifiers {
                    guard let expected = baseline[identifier], let actual = frames[identifier] else { XCTFail("missing \(identifier)"); continue }
                    XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 0.001)
                    XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 0.001)
                    XCTAssertEqual(actual.width, expected.width, accuracy: 0.001)
                    XCTAssertEqual(actual.height, expected.height, accuracy: 0.001)
                }
            } else { baseline = frames }
        }
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
    func boundsContain(_ productionIdentifier: String) -> Bool { guard let view = locationMarker(for: productionIdentifier) else { return false }; return hostingView.bounds.contains(hostingView.convert(view.bounds, from: view)) }
    func locationMarkerFrame(_ productionIdentifier: String) -> NSRect? { guard let view = locationMarker(for: productionIdentifier) else { return nil }; return hostingView.convert(view.bounds, from: view) }
    func click(_ productionIdentifier: String) throws { guard let view = locationMarker(for: productionIdentifier) else { throw XCTSkip("control marker missing") }; let location = view.convert(.init(x: view.bounds.midX, y: view.bounds.midY), to: nil); for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] { if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { window.sendEvent(event) } }; render() }
    private func render() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); window.layoutIfNeeded(); hostingView.layoutSubtreeIfNeeded() }
    private func view(_ identifier: String) -> NSView? { allViews(hostingView).first { $0.accessibilityIdentifier() == identifier } }
    private func locationMarker(for productionIdentifier: String) -> NSView? { view("\(productionIdentifier).marker") }
    private func allViews(_ view: NSView) -> [NSView] {
        let children = view.subviews + ((view.accessibilityChildren() as? [NSView]) ?? [])
        return [view] + children.flatMap(allViews)
    }
}
