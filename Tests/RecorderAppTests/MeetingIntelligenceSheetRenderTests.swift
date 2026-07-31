import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class MeetingIntelligenceSheetRenderTests: XCTestCase {
    func test860By680SheetRendersMeetingIntelligenceAndNeverEmbedsPlaybackView() throws {
        let host = try SheetRenderHost(size: .init(width: 860, height: 680)) {
            TranscriptEditorView(
                session: self.session(),
                load: { "Draft transcript" },
                save: { _ in },
                export: {},
                copy: {},
                meetingIntelligencePresentation: .init(
                    phase: .ready,
                    summary: "A concise meeting summary.",
                    suggestedTitle: "Atlas planning",
                    statusMessage: "Ready.",
                    model: "test-model",
                    titleIsProtected: true,
                    unavailableReason: nil
                )
            )
        }
        defer { host.close() }

        for identifier in [
            RecorderActionID.meetingIntelligenceCard,
            RecorderActionID.meetingIntelligenceStatus,
            RecorderActionID.meetingIntelligenceSummary,
            RecorderActionID.meetingIntelligenceSuggestedTitle,
            RecorderActionID.meetingIntelligenceApplyTitle,
            RecorderActionID.meetingIntelligenceManualTitleProtection,
            RecorderActionID.saveTranscript
        ] {
            XCTAssertTrue(host.contains(identifier), "Missing rendered marker: \(identifier)")
        }
        XCTAssertFalse(host.containsView(named: "AVPlayerView"))
        XCTAssertFalse(host.containsView(named: "RecordingPlaybackView"))
    }

    func testWideSheetKeepsSectionAndFooterReachableAfterReopen() throws {
        let makeView = {
            TranscriptEditorView(
                session: self.session(), load: { "Draft" }, save: { _ in },
                export: {}, copy: {}
            )
        }
        let first = try SheetRenderHost(size: .init(width: 1_280, height: 800), root: makeView())
        XCTAssertTrue(first.contains(RecorderActionID.saveTranscript))
        first.close()

        let reopened = try SheetRenderHost(size: .init(width: 1_280, height: 800), root: makeView())
        defer { reopened.close() }
        XCTAssertTrue(reopened.contains(RecorderActionID.meetingIntelligenceCard))
        XCTAssertTrue(reopened.contains(RecorderActionID.saveTranscript))
    }

    private func session() -> RecordingSession {
        let folder = URL(fileURLWithPath: "/tmp/meeting-intelligence-sheet-\(UUID().uuidString)")
        return RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 12,
            fileSize: 1,
            metadata: .init(title: "Transcript detail")
        )
    }
}

@MainActor
private final class SheetRenderHost<Root: View> {
    private let hostingView: NSHostingView<Root>
    private let window: NSWindow

    convenience init(size: CGSize, @ViewBuilder root: () -> Root) throws {
        try self.init(size: size, root: root())
    }

    init(size: CGSize, root: Root) throws {
        hostingView = NSHostingView(rootView: root)
        let frame = NSRect(origin: .zero, size: size)
        hostingView.frame = frame
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    func contains(_ identifier: String) -> Bool {
        hostingView.accessibilityIdentifier() == identifier
            || allViews(startingAt: hostingView).contains {
                $0.accessibilityIdentifier() == identifier
            }
            || findAccessibility(in: hostingView.accessibilityChildren() ?? [], identifier: identifier) != nil
    }

    func containsView(named className: String) -> Bool {
        allViews(startingAt: hostingView).contains { String(describing: type(of: $0)).contains(className) }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func findAccessibility(in elements: [Any], identifier: String) -> (any NSAccessibilityElementProtocol)? {
        for element in elements {
            if let accessible = element as? any NSAccessibilityElementProtocol,
               accessible.accessibilityIdentifier?() == identifier { return accessible }
            if let view = element as? NSView,
               let found = findAccessibility(in: view.accessibilityChildren() ?? [], identifier: identifier) { return found }
            if let object = element as? NSObject,
               object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [Any],
               let found = findAccessibility(in: children, identifier: identifier) { return found }
        }
        return nil
    }

    private func allViews(startingAt view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }
}
