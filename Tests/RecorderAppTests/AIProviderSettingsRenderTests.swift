import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class AIProviderSettingsRenderTests: XCTestCase {
    func testProviderSpecificFieldsAndContentSurfacesRemainReachableAtSupportedSizes() throws {
        let repository = RecordingProviderRepository(hasAPIKey: true)
        let model = makeConfiguredModel(repository: repository)
        let host = ProviderSettingsRenderHost(model: model, size: .init(width: 860, height: 680))
        defer { host.close() }

        for title in ["Connection", "Models", "Transcription"] {
            XCTAssertTrue(host.containsText(title), "Missing provider content surface: \(title)")
        }
        XCTAssertTrue(host.containsMarker(for: RecorderActionID.providerKind))
        XCTAssertTrue(host.containsMarker(for: RecorderActionID.providerBaseURL))
        XCTAssertFalse(host.containsMarker(for: RecorderActionID.providerHKTGroupID))
        XCTAssertFalse(host.containsMarker(for: RecorderActionID.providerHKTResolvedURL))
        assertImportantControlsAreFullyContained(in: host)

        model.selectedProviderKind = .hktGenAI
        host.render()

        XCTAssertTrue(host.containsMarker(for: RecorderActionID.providerKind))
        XCTAssertTrue(host.containsMarker(for: RecorderActionID.providerHKTGroupID))
        XCTAssertTrue(host.containsMarker(for: RecorderActionID.providerHKTResolvedURL))
        XCTAssertFalse(host.containsMarker(for: RecorderActionID.providerBaseURL))
        assertImportantControlsAreFullyContained(in: host)

        let wideHost = ProviderSettingsRenderHost(model: model, size: .init(width: 1_280, height: 800))
        defer { wideHost.close() }
        XCTAssertTrue(wideHost.containsMarker(for: RecorderActionID.providerHKTGroupID))
        XCTAssertTrue(wideHost.containsMarker(for: RecorderActionID.providerHKTResolvedURL))
        assertImportantControlsAreFullyContained(in: wideHost)
    }

    func testSaveAndBlockingConnectionTestUseTheRenderedControlsAndRealModelState() async throws {
        let repository = RecordingProviderRepository(hasAPIKey: true)
        let client = BlockingProviderClient()
        let model = makeConfiguredModel(repository: repository, client: client)
        let host = ProviderSettingsRenderHost(model: model, size: .init(width: 860, height: 680))
        defer { host.close() }

        try host.clickRenderedControl(RecorderActionID.providerSave)
        XCTAssertEqual(repository.saveCount, 1, "Save must invoke the injected repository exactly once")

        try host.clickRenderedControl(RecorderActionID.providerTest)
        await client.waitForRequest()
        host.render()

        XCTAssertTrue(model.isTesting)
        XCTAssertTrue(host.containsText("Testing connection…"))
        XCTAssertTrue(host.containsMarker(for: RecorderActionID.providerStatus))
        try host.clickRenderedControl(RecorderActionID.providerTest)
        let requestCountWhileDisabled = await client.requestCount()
        XCTAssertEqual(requestCountWhileDisabled, 1, "Disabled Test must not start a second real request")

        await client.complete(with: .init(supportsModelDiscovery: true, models: ["discovered-model"]))
        await waitUntil { !model.isTesting }
        host.render()
        XCTAssertTrue(host.containsText("Connected; model list available"))
    }

    private func makeConfiguredModel(
        repository: RecordingProviderRepository,
        client: any ProviderConnectionTesting = ImmediateProviderClient()
    ) -> AIProviderSettingsModel {
        let model = AIProviderSettingsModel(repository: repository, client: client, loadImmediately: false)
        model.baseURLText = "https://api.example.com/v1"
        model.asrModel = "asr-model"
        model.llmModel = "llm-model"
        model.language = MeetingLanguage.cantonese.rawValue
        return model
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func assertImportantControlsAreFullyContained(in host: ProviderSettingsRenderHost) {
        for identifier in [
            RecorderActionID.providerPrompt,
            RecorderActionID.providerSave,
            RecorderActionID.providerTest,
            RecorderActionID.providerRemoveKey,
            RecorderActionID.providerStatus
        ] {
            XCTAssertTrue(host.isFullyContained(identifier), "Clipped provider control: \(identifier)")
        }
    }
}

@MainActor
private final class ProviderSettingsRenderHost {
    private let hostingView: NSHostingView<AIProviderSettingsView>
    private let window: NSWindow

    init(model: AIProviderSettingsModel, size: CGSize) {
        hostingView = NSHostingView(rootView: AIProviderSettingsView(model: model))
        let frame = NSRect(origin: .zero, size: size)
        hostingView.frame = frame
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        render()
    }

    func containsMarker(for identifier: String) -> Bool { view(for: identifier + ".marker") != nil }

    func containsText(_ text: String) -> Bool {
        allViews(startingAt: hostingView).compactMap { $0 as? NSTextField }.contains { $0.stringValue == text }
            || allViews(startingAt: hostingView).contains { $0.accessibilityLabel() == text }
            || allAccessibilityElements(in: hostingView.accessibilityChildren() ?? []).contains {
                accessibilityString($0, key: "accessibilityLabel") == text
                    || accessibilityString($0, key: "accessibilityValue") == text
            }
    }

    func isFullyContained(_ identifier: String) -> Bool {
        guard let view = view(for: identifier + ".marker") else { return false }
        return window.frame.contains(view.accessibilityFrame())
    }

    func clickRenderedControl(_ identifier: String) throws {
        let marker = try XCTUnwrap(view(for: identifier + ".marker"), "Missing control location marker: \(identifier)")
        let location = marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
            window.sendEvent(event)
        }
        render()
    }

    func render() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func view(for identifier: String) -> NSView? {
        allViews(startingAt: hostingView).first { $0.accessibilityIdentifier() == identifier }
    }

    private func allAccessibilityElements(in elements: [Any]) -> [any NSAccessibilityElementProtocol] {
        elements.flatMap { element in
            let children: [Any]
            if let view = element as? NSView {
                children = view.accessibilityChildren() ?? []
            } else if let object = element as? NSObject,
                      object.responds(to: NSSelectorFromString("accessibilityChildren")) {
                children = object.value(forKey: "accessibilityChildren") as? [Any] ?? []
            } else {
                children = []
            }
            return ([element as? any NSAccessibilityElementProtocol].compactMap { $0 })
                + allAccessibilityElements(in: children)
        }
    }

    private func accessibilityString(_ element: any NSAccessibilityElementProtocol, key: String) -> String? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? String
    }

    private func allViews(startingAt view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }
}

private struct ImmediateProviderClient: ProviderConnectionTesting {
    func testConnection(for _: OpenAICompatibleProviderSnapshot) async throws -> ProviderConnectionReport {
        .init(supportsModelDiscovery: true, models: [])
    }
}

private actor BlockingProviderClient: ProviderConnectionTesting {
    private var continuations: [CheckedContinuation<ProviderConnectionReport, Error>] = []
    private var requestsStarted = 0

    func testConnection(for _: OpenAICompatibleProviderSnapshot) async throws -> ProviderConnectionReport {
        requestsStarted += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForRequest() async {
        while requestsStarted == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    func requestCount() -> Int { requestsStarted }

    func complete(with report: ProviderConnectionReport) {
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume(returning: report) }
    }
}
