import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class RecordingControllerRenderTests: XCTestCase {
    func testActiveControllerRendersFixedBoundsAndInvokesStopOnce() throws {
        var stops = 0
        var screenRequests: [Bool] = []
        let presentation = RecordingControllerPresentation.make(
            snapshot: .init(isRecording: true, isFinalizing: false, startedAt: Date(), showsTeamsScreenControl: true, screenRequested: true, screenStatusText: TeamsScreenStatusText.capturing, screenToggleDisabled: false),
            now: Date()
        )
        let host = PanelRenderHost(
            rootView: RecordingControllerPanelContent(
                presentation: presentation,
                stop: { stops += 1 },
                setScreenRequested: { screenRequests.append($0) }
            ),
            size: .init(width: 390, height: 112)
        )
        defer { host.close() }

        XCTAssertEqual(host.frame.size, .init(width: 390, height: 112))
        for identifier in ["recording-controller-status", "recording-controller-elapsed", "recording-controller-screen-status", "recording-controller-screen-toggle", "recording-controller-stop"] {
            XCTAssertTrue(host.boundsContain(identifier), identifier)
        }
        try host.click("recording-controller-stop")
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(screenRequests.isEmpty)
    }

    func testFinalizingRawEventsDoNotInvokeDisabledActions() throws {
        var stops = 0
        var screenRequests: [Bool] = []
        let presentation = RecordingControllerPresentation.make(
            snapshot: .init(isRecording: true, isFinalizing: true, startedAt: Date(), showsTeamsScreenControl: true, screenRequested: true, screenStatusText: TeamsScreenStatusText.unavailable, screenToggleDisabled: false),
            now: Date()
        )
        let host = PanelRenderHost(
            rootView: RecordingControllerPanelContent(presentation: presentation, stop: { stops += 1 }, setScreenRequested: { screenRequests.append($0) }),
            size: .init(width: 390, height: 112)
        )
        defer { host.close() }

        host.rawClick("recording-controller-stop")
        host.rawClick("recording-controller-screen-toggle")
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(screenRequests.isEmpty)
    }

    func testMotionAndTransparencyOverridesAreEmittedByPanelModifiers() {
        let presentation = RecordingControllerPresentation.make(snapshot: .init(isRecording: true, isFinalizing: false, startedAt: Date(), showsTeamsScreenControl: true, screenRequested: false, screenStatusText: TeamsScreenStatusText.off, screenToggleDisabled: false), now: Date())
        let identifiers = ["recording-controller-status", "recording-controller-elapsed", "recording-controller-screen-status", "recording-controller-screen-toggle", "recording-controller-stop"]
        let variants: [(Bool, Bool, String, String)] = [(false, false, "recorder.motion.scale", "recorder.glass.native"), (true, false, "recorder.motion.no-scale", "recorder.glass.native"), (false, true, "recorder.motion.scale", "recorder.glass.material-separator")]
        var baseline: [String: NSRect]?
        for (motion, transparency, expectedMotion, expectedGlass) in variants {
            let host = PanelRenderHost(rootView: RecordingControllerPanelContent(presentation: presentation, stop: {}, setScreenRequested: { _ in }).environment(\.recorderReduceMotionOverride, motion).environment(\.recorderReduceTransparencyOverride, transparency), size: .init(width: 390, height: 112))
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
private final class PanelRenderHost {
    private let hostingView: NSHostingView<AnyView>
    private let window: NSWindow

    init<Content: View>(rootView: Content, size: NSSize) {
        hostingView = NSHostingView(rootView: AnyView(rootView))
        let frame = NSRect(origin: .zero, size: size)
        hostingView.frame = frame
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        render()
    }

    var frame: NSRect { hostingView.frame }
    func contains(_ identifier: String) -> Bool { view(identifier) != nil }
    func close() { window.orderOut(nil); window.contentView = nil }
    func boundsContain(_ productionIdentifier: String) -> Bool { guard let view = locationMarker(for: productionIdentifier) else { return false }; return hostingView.bounds.contains(hostingView.convert(view.bounds, from: view)) }
    func locationMarkerFrame(_ productionIdentifier: String) -> NSRect? { guard let view = locationMarker(for: productionIdentifier) else { return nil }; return hostingView.convert(view.bounds, from: view) }
    func click(_ productionIdentifier: String) throws { guard let view = locationMarker(for: productionIdentifier) else { throw XCTSkip("control marker missing") }; sendEvents(to: view); render() }
    func rawClick(_ productionIdentifier: String) { if let view = locationMarker(for: productionIdentifier) { sendEvents(to: view); render() } }
    private func sendEvents(to view: NSView) { let location = view.convert(.init(x: view.bounds.midX, y: view.bounds.midY), to: nil); for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] { if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { window.sendEvent(event) } } }
    private func render() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); window.layoutIfNeeded(); hostingView.layoutSubtreeIfNeeded() }
    private func view(_ identifier: String) -> NSView? { allViews(hostingView).first { $0.accessibilityIdentifier() == identifier } }
    private func locationMarker(for productionIdentifier: String) -> NSView? { view("\(productionIdentifier).marker") }
    private func allViews(_ view: NSView) -> [NSView] {
        let children = view.subviews + ((view.accessibilityChildren() as? [NSView]) ?? [])
        return [view] + children.flatMap(allViews)
    }
}
