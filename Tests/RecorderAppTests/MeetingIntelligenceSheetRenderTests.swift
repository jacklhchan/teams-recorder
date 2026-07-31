import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class MeetingIntelligenceSheetRenderTests: XCTestCase {
    func testTranscriptDetailSourceDoesNotDeclareEmbeddedPlaybackViews() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/RecorderApp/UI/RecordingsLibraryView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("AVPlayerView"))
        XCTAssertFalse(source.contains("RecordingPlaybackView"))
    }

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
            XCTAssertTrue(
                host.windowContentRect.contains(try XCTUnwrap(host.frame(for: identifier))),
                "\(identifier) must remain visible in an 860×680 transcript detail window."
            )
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
        XCTAssertGreaterThan(
            try XCTUnwrap(reopened.frame(for: "recorder.transcript.detail.root")).width,
            860,
            "Wide host must expand the transcript detail beyond its 860-point minimum."
        )
        XCTAssertTrue(reopened.contains(RecorderActionID.meetingIntelligenceCard))
        XCTAssertTrue(reopened.contains(RecorderActionID.saveTranscript))
        for identifier in [
            RecorderActionID.meetingIntelligenceCard,
            RecorderActionID.saveTranscript
        ] {
            XCTAssertTrue(
                reopened.windowContentRect.contains(try XCTUnwrap(reopened.frame(for: identifier))),
                "\(identifier) must be reachable in the wide window."
            )
        }
    }

    func testProjectionUpdatesKeepOpenDraftButClosingAndReopeningLoadsStoredText() throws {
        let state = TranscriptDetailLifecycleState(session: session())
        let host = try TranscriptDetailLifecycleHost(state: state)
        defer { host.close() }

        host.replaceEditorText(with: "Unsaved transcript draft")
        XCTAssertEqual(host.editorText, "Unsaved transcript draft")

        for index in 0 ..< 3 {
            state.publishUnrelatedUpdate()
            state.session = self.session(
                basedOn: state.session,
                title: "Generated title \(index)",
                favorite: index.isMultiple(of: 2)
            )
            host.render()
            XCTAssertEqual(host.editorText, "Unsaved transcript draft")
            XCTAssertEqual(host.accessibilityLabel(for: RecorderActionID.transcriptDetailTitle), "Generated title \(index)")
            XCTAssertEqual(host.accessibilityLabel(for: RecorderActionID.transcriptDetailFavorite), index.isMultiple(of: 2) ? "favorite" : "not-favorite")
        }

        state.closeDetail()
        host.render()
        state.reopenDetail()
        host.render()

        XCTAssertEqual(host.editorText, "Stored transcript")
    }

    private func session(
        basedOn existing: RecordingSession? = nil,
        title: String = "Transcript detail",
        favorite: Bool = false
    ) -> RecordingSession {
        let folder = existing?.folderURL ?? URL(fileURLWithPath: "/tmp/meeting-intelligence-sheet-\(UUID().uuidString)")
        return RecordingSession(
            id: existing?.id ?? folder,
            folderURL: folder,
            recordingURL: existing?.recordingURL ?? folder.appendingPathComponent("recording.m4a"),
            createdAt: existing?.createdAt ?? .now,
            duration: existing?.duration ?? 12,
            fileSize: existing?.fileSize ?? 1,
            metadata: .init(title: title, isFavorite: favorite)
        )
    }
}

@MainActor
private final class TranscriptDetailLifecycleState: ObservableObject {
    @Published var session: RecordingSession
    @Published var isDetailOpen = true
    @Published private var unrelatedRevision = 0

    init(session: RecordingSession) {
        self.session = session
    }

    func publishUnrelatedUpdate() {
        unrelatedRevision += 1
    }

    func closeDetail() {
        isDetailOpen = false
    }

    func reopenDetail() {
        isDetailOpen = true
    }
}

@MainActor
private struct TranscriptDetailLifecycleRoot: View {
    @ObservedObject var state: TranscriptDetailLifecycleState

    var body: some View {
        if state.isDetailOpen {
            TranscriptEditorView(
                session: state.session,
                resolvedSession: state.session,
                load: { "Stored transcript" },
                save: { _ in },
                export: {},
                copy: {}
            )
        }
    }
}

@MainActor
private final class TranscriptDetailLifecycleHost {
    private let hostingView: NSHostingView<TranscriptDetailLifecycleRoot>
    private let window: NSWindow

    init(state: TranscriptDetailLifecycleState) throws {
        hostingView = NSHostingView(rootView: .init(state: state))
        let frame = NSRect(x: 0, y: 0, width: 860, height: 680)
        hostingView.frame = frame
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        render()
        _ = try XCTUnwrap(editor)
    }

    var editorText: String { editor?.string ?? "" }

    func replaceEditorText(with text: String) {
        guard let editor else {
            XCTFail("Transcript editor was not rendered")
            return
        }
        editor.string = text
        editor.didChangeText()
        render()
    }

    func accessibilityLabel(for identifier: String) -> String? {
        view(for: identifier)?.accessibilityLabel()
            ?? accessibilityString(
                accessibilityElement(for: identifier),
                key: "accessibilityLabel"
            )
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

    private var editor: NSTextView? {
        allViews(startingAt: hostingView).compactMap { $0 as? NSTextView }.first
    }

    private func view(for identifier: String) -> NSView? {
        allViews(startingAt: hostingView).first { $0.accessibilityIdentifier() == identifier }
    }

    private func accessibilityElement(for identifier: String) -> (any NSAccessibilityElementProtocol)? {
        func find(in elements: [Any]) -> (any NSAccessibilityElementProtocol)? {
            for element in elements {
                if let accessibility = element as? any NSAccessibilityElementProtocol,
                   accessibility.accessibilityIdentifier?() == identifier {
                    return accessibility
                }
                if let view = element as? NSView,
                   let found = find(in: view.accessibilityChildren() ?? []) {
                    return found
                }
            }
            return nil
        }
        return find(in: hostingView.accessibilityChildren() ?? [])
    }

    private func accessibilityString(
        _ element: (any NSAccessibilityElementProtocol)?,
        key: String
    ) -> String? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(key)) else {
            return nil
        }
        return object.value(forKey: key) as? String
    }

    private func allViews(startingAt view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
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

    var windowContentRect: CGRect {
        let rect = window.contentLayoutRect
        return CGRect(origin: window.convertPoint(toScreen: rect.origin), size: rect.size)
    }

    func frame(for identifier: String) -> CGRect? {
        if let view = allViews(startingAt: hostingView).first(where: {
            $0.accessibilityIdentifier() == identifier
        }) {
            return view.accessibilityFrame()
        }
        return findAccessibility(in: hostingView.accessibilityChildren() ?? [], identifier: identifier)?
            .accessibilityFrame()
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
