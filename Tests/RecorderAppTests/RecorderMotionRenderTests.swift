import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class RecorderMotionRenderTests: XCTestCase {
    func testMotionControlsExposeStableMarkersAndPreserveEnabledActionSemantics() throws {
        let state = MotionRenderState()
        let host = MotionRenderHost(state: state)
        defer { host.close() }

        XCTAssertEqual(
            RecorderActionID.primaryActionCluster,
            "recorder.visual.primary-action-cluster"
        )
        XCTAssertEqual(
            RecorderActionID.indeterminateProgress,
            "recorder.visual.indeterminate-progress"
        )
        XCTAssertTrue(host.contains(RecorderActionID.primaryActionCluster))
        XCTAssertTrue(host.contains(RecorderActionID.indeterminateProgress))
        XCTAssertTrue(host.click(RecorderActionID.primaryActionCluster))
        XCTAssertEqual(state.acceptedClicks, 1)

        state.isEnabled = false
        host.render()

        XCTAssertFalse(host.isEnabled(RecorderActionID.primaryActionCluster))
        host.rawClick(RecorderActionID.primaryActionCluster)
        XCTAssertEqual(state.acceptedClicks, 1)
    }
}

@MainActor
private final class MotionRenderState: ObservableObject {
    @Published var isEnabled = true
    @Published var acceptedClicks = 0
}

@MainActor
private struct MotionRenderFixture: View {
    @ObservedObject var state: MotionRenderState

    var body: some View {
        VStack {
            Button("Primary action") {
                state.acceptedClicks += 1
            }
            .buttonStyle(RecorderMotionButtonStyle(prominence: .prominent, tint: .accentColor))
            .accessibilityIdentifier(RecorderActionID.primaryActionCluster)
            .background(
                MotionRenderMarker(
                    identifier: RecorderActionID.primaryActionCluster,
                    isEnabled: state.isEnabled
                )
            )
            .disabled(!state.isEnabled)

            RecorderStatusTransition(value: state.isEnabled) { isEnabled in
                Text(isEnabled ? "Enabled" : "Disabled")
            }

            RecorderIndeterminateProgress()
                .accessibilityIdentifier(RecorderActionID.indeterminateProgress)
                .background(
                    MotionRenderMarker(
                        identifier: RecorderActionID.indeterminateProgress,
                        isEnabled: true
                    )
                )
        }
        .padding()
    }
}

private struct MotionRenderMarker: NSViewRepresentable {
    let identifier: String
    let isEnabled: Bool

    func makeNSView(context _: Context) -> MotionRenderMarkerView {
        let view = MotionRenderMarkerView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityEnabled(isEnabled)
        return view
    }

    func updateNSView(_ view: MotionRenderMarkerView, context _: Context) {
        view.setAccessibilityEnabled(isEnabled)
    }
}

private final class MotionRenderMarkerView: NSView {}

@MainActor
private final class MotionRenderHost {
    private let hostingView: NSHostingView<MotionRenderFixture>
    private let window: NSWindow

    init(state: MotionRenderState) {
        hostingView = NSHostingView(rootView: MotionRenderFixture(state: state))
        let frame = NSRect(x: 0, y: 0, width: 420, height: 240)
        hostingView.frame = frame
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        render()
    }

    func contains(_ identifier: String) -> Bool {
        view(for: identifier) != nil
    }

    func isEnabled(_ identifier: String) -> Bool {
        view(for: identifier)?.isAccessibilityEnabled() ?? false
    }

    @discardableResult
    func click(_ identifier: String) -> Bool {
        guard let view = view(for: identifier), view.isAccessibilityEnabled() else {
            return false
        }
        let location = view.convert(
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: nil
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else {
                return false
            }
            window.sendEvent(event)
        }
        render()
        return true
    }

    func rawClick(_ identifier: String) {
        guard let view = view(for: identifier) else { return }
        let location = view.convert(
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: nil
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            window.sendEvent(event)
        }
        render()
    }

    func render() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func view(for identifier: String) -> NSView? {
        allViews(startingAt: hostingView).first {
            $0.accessibilityIdentifier() == identifier
        }
    }

    private func allViews(startingAt view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews(startingAt:))
    }
}
