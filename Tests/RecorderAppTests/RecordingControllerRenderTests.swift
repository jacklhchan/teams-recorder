import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class RecordingControllerRenderTests: XCTestCase {
    func testExpandedPanelKeepsRecordingIndicatorAndUsesCollapseEye() throws {
        let host = PanelRenderHost(
            rootView: RecordingControllerPanelFixture(state: .expanded),
            size: .init(width: 390, height: 180)
        )
        defer { host.close() }

        XCTAssertTrue(
            host.contains(
                "\(RecordingControllerAccessibility.recordingIndicatorID).marker"
            )
        )
        XCTAssertTrue(
            host.contains(
                "\(RecordingControllerAccessibility.panelToggleID).marker"
            )
        )
        XCTAssertFalse(
            host.contains(
                "\(RecordingControllerAccessibility.recordingIndicatorToggleID).marker"
            )
        )
    }

    func testProductionMicrophoneButtonMutesThenUnmutesRecorderLocally() async throws {
        let model = AppModel(
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false
        )
        model.resolvedCaptureSelection = .application(.init(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        ))
        let host = PanelRenderHost(
            rootView: RecordingControllerView(model: model),
            size: .init(width: 390, height: 180)
        )
        defer { host.close() }

        try host.click(RecordingControllerAccessibility.microphoneMuteID)
        await waitUntil { model.localMicMuted }
        try host.click(RecordingControllerAccessibility.microphoneMuteID)
        await waitUntil { !model.localMicMuted }

        XCTAssertFalse(model.localMicMuted)
    }

    func testActiveControllerRendersFixedBoundsAndInvokesStopOnce() throws {
        var stops = 0
        var microphoneMuteToggles = 0
        var screenRequests: [Bool] = []
        let presentation = RecordingControllerPresentation.make(
            snapshot: .init(isRecording: true, isFinalizing: false, startedAt: Date(), showsTeamsScreenControl: true, screenRequested: true, screenStatusText: TeamsScreenStatusText.capturing, screenToggleDisabled: false),
            now: Date()
        )
        let host = PanelRenderHost(
            rootView: RecordingControllerPanelContent(
                presentation: presentation,
                stop: { stops += 1 },
                toggleMicrophoneMute: { microphoneMuteToggles += 1 },
                setScreenRequested: { screenRequests.append($0) },
                systemLevel: .init(rms: -24, peak: -12, samples: [0.25, 0.5]),
                microphoneLevel: .init(rms: -18, peak: -6, samples: [0.35, 0.65]),
                isSystemConnected: true,
                isMicrophoneConnected: true,
                isMicrophoneMuted: false,
                isLocalMicrophoneMuted: false,
                panelState: .expanded
            ),
            size: .init(width: 390, height: 180)
        )
        defer { host.close() }

        XCTAssertEqual(host.frame.size, .init(width: 390, height: 180))
        XCTAssertTrue(host.contains(RecordingControllerAccessibility.systemWaveformID))
        XCTAssertTrue(host.contains(RecordingControllerAccessibility.microphoneWaveformID))
        XCTAssertTrue(host.boundsContain(RecordingControllerAccessibility.systemWaveformID))
        XCTAssertTrue(host.boundsContain(RecordingControllerAccessibility.microphoneWaveformID))
        XCTAssertTrue(host.boundsContain(RecordingControllerAccessibility.microphoneMuteID))
        for identifier in RecordingControllerAccessibility.allIDs {
            XCTAssertTrue(host.boundsContain(identifier), identifier)
        }
        try host.click(RecordingControllerAccessibility.stopID)
        try host.click(RecordingControllerAccessibility.microphoneMuteID)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(microphoneMuteToggles, 1)
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
            rootView: RecordingControllerPanelContent(
                presentation: presentation,
                stop: { stops += 1 },
                toggleMicrophoneMute: {},
                setScreenRequested: { screenRequests.append($0) },
                systemLevel: .init(rms: -24, peak: -12, samples: [0.25, 0.5]),
                microphoneLevel: .init(rms: -18, peak: -6, samples: [0.35, 0.65]),
                isSystemConnected: true,
                isMicrophoneConnected: true,
                isMicrophoneMuted: false,
                isLocalMicrophoneMuted: false,
                panelState: .expanded
            ),
            size: .init(width: 390, height: 180)
        )
        defer { host.close() }

        try host.rawClick(RecordingControllerAccessibility.stopID)
        try host.rawClick(RecordingControllerAccessibility.screenToggleID)
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(screenRequests.isEmpty)
    }

    func testMotionAndTransparencyOverridesAreEmittedByPanelModifiers() {
        let presentation = RecordingControllerPresentation.make(snapshot: .init(isRecording: true, isFinalizing: false, startedAt: Date(), showsTeamsScreenControl: true, screenRequested: false, screenStatusText: TeamsScreenStatusText.off, screenToggleDisabled: false), now: Date())
        let identifiers = RecordingControllerAccessibility.allIDs
        let variants: [(Bool, Bool, String, String)] = [(false, false, "recorder.motion.scale", "recorder.glass.native"), (true, false, "recorder.motion.no-scale", "recorder.glass.native"), (false, true, "recorder.motion.scale", "recorder.glass.material-separator")]
        var baseline: [String: NSRect]?
        for (motion, transparency, expectedMotion, expectedGlass) in variants {
            XCTAssertEqual(RecordingControllerAccessibility.allIDs, identifiers)
            XCTAssertEqual(RecordingControllerAccessibility.stopLabel, "Stop recording")
            XCTAssertEqual(RecordingControllerAccessibility.screenCaptureLabel, "Capture Teams screen")
            XCTAssertEqual(RecordingControllerAccessibility.screenCaptureValue(isOn: false), "Off")
            XCTAssertEqual(RecordingControllerAccessibility.screenCaptureValue(isOn: true), "On")
            let host = PanelRenderHost(
                rootView: RecordingControllerPanelContent(
                    presentation: presentation,
                    stop: {},
                    toggleMicrophoneMute: {},
                    setScreenRequested: { _ in },
                    systemLevel: .init(rms: -24, peak: -12, samples: [0.25, 0.5]),
                    microphoneLevel: .init(rms: -18, peak: -6, samples: [0.35, 0.65]),
                    isSystemConnected: true,
                    isMicrophoneConnected: true,
                    isMicrophoneMuted: false,
                    isLocalMicrophoneMuted: false,
                    panelState: .expanded
                )
                .environment(\.recorderReduceMotionOverride, motion)
                .environment(\.recorderReduceTransparencyOverride, transparency),
                size: .init(width: 390, height: 180)
            )
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

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private struct RecordingControllerPanelFixture: View {
    let state: FloatingPanelPresentationState

    var body: some View {
        RecordingControllerPanelContent(
            presentation: RecordingControllerPresentation.make(
                snapshot: .init(
                    isRecording: true,
                    isFinalizing: false,
                    startedAt: Date(),
                    showsTeamsScreenControl: false,
                    screenRequested: false,
                    screenStatusText: TeamsScreenStatusText.off,
                    screenToggleDisabled: false
                ),
                now: Date()
            ),
            stop: {},
            toggleMicrophoneMute: {},
            setScreenRequested: { _ in },
            systemLevel: .init(),
            microphoneLevel: .init(),
            isSystemConnected: true,
            isMicrophoneConnected: true,
            isMicrophoneMuted: false,
            isLocalMicrophoneMuted: false,
            panelState: state
        )
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
    func click(_ productionIdentifier: String) throws { try rawClick(productionIdentifier) }
    func rawClick(_ productionIdentifier: String) throws { let view = try XCTUnwrap(locationMarker(for: productionIdentifier), "missing marker for \(productionIdentifier)"); try sendEvents(to: view); render() }
    private func sendEvents(to view: NSView) throws { let location = view.convert(.init(x: view.bounds.midX, y: view.bounds.midY), to: nil); for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] { let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0), "missing \(type) event"); window.sendEvent(event) } }
    private func render() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); window.layoutIfNeeded(); hostingView.layoutSubtreeIfNeeded() }
    private func view(_ identifier: String) -> NSView? { allViews(hostingView).first { $0.accessibilityIdentifier() == identifier } }
    private func locationMarker(for productionIdentifier: String) -> NSView? { view("\(productionIdentifier).marker") }
    private func allViews(_ view: NSView) -> [NSView] {
        let children = view.subviews + ((view.accessibilityChildren() as? [NSView]) ?? [])
        return [view] + children.flatMap(allViews)
    }
}
