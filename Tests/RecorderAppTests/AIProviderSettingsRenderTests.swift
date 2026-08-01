import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class AIProviderSettingsRenderTests: XCTestCase {
    func testProductionSettingsFormKeepsProviderControlLocationsReachableAtSupportedSizes() throws {
        let repository = RecordingProviderRepository(hasAPIKey: true)
        let defaultsSuite = "provider-render-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let appModel = AppModel(
            defaults: defaults,
            providerRepository: repository,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            virtualMicStateProvider: { .absent }
        )
        let model = appModel.aiProviderSettingsModel
        model.baseURLText = "https://api.example.com/v1"
        model.asrModel = "asr-model"
        model.llmModel = "llm-model"
        model.language = MeetingLanguage.cantonese.rawValue
        let supportedSizes = [
            CGSize(width: 860, height: 680),
            CGSize(width: 1_280, height: 800)
        ]
        for size in supportedSizes {
            model.selectedProviderKind = .openAICompatible
            let host = ProviderSettingsProductionHost(model: appModel, size: size)
            assertGenericProviderLocationsAreReachable(in: host)

            model.selectedProviderKind = .hktGenAI
            host.render()
            XCTAssertTrue(host.reveal(RecorderActionID.providerHKTGroupID))
            XCTAssertTrue(host.reveal(RecorderActionID.providerHKTResolvedURL))
            assertSharedProviderLocationsAreReachable(in: host)
            host.close()
        }
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
        let requestStarted = await client.waitForRequest()
        XCTAssertTrue(requestStarted)
        host.render()

        XCTAssertTrue(model.isTesting)
        try host.clickRenderedControl(RecorderActionID.providerTest)
        let requestCountWhileDisabled = await client.requestCount()
        await client.completeAll(with: .init(supportsModelDiscovery: true, models: ["discovered-model"]))
        XCTAssertEqual(requestCountWhileDisabled, 1, "Disabled Test must not start a second real request")
        let settled = await waitUntil { !model.isTesting }
        XCTAssertTrue(settled)
        host.render()
        XCTAssertEqual(model.status, "Connected; model list available")
        XCTAssertEqual(model.discoveredModels, ["discovered-model"])
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
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func assertGenericProviderLocationsAreReachable(in host: ProviderSettingsProductionHost) {
        XCTAssertTrue(host.reveal(RecorderActionID.providerBaseURL))
        assertSharedProviderLocationsAreReachable(in: host)
    }

    private func assertSharedProviderLocationsAreReachable(in host: ProviderSettingsProductionHost) {
        for identifier in [
            RecorderActionID.providerKind,
            RecorderActionID.providerAPIKey,
            RecorderActionID.providerASRModel,
            RecorderActionID.providerLLMModel,
            RecorderActionID.providerLanguage,
            RecorderActionID.providerPrompt,
            RecorderActionID.providerSave,
            RecorderActionID.providerTest,
            RecorderActionID.providerRemoveKey,
            RecorderActionID.providerStatus
        ] {
            XCTAssertTrue(host.reveal(identifier), "Unreachable provider control: \(identifier)")
        }
    }
}

@MainActor
private final class ProviderSettingsProductionHost {
    private let hostingView: NSHostingView<RecorderSettingsView>
    private let window: NSWindow
    init(model: AppModel, size: CGSize) {
        hostingView = NSHostingView(rootView: RecorderSettingsView(model: model))
        let frame = NSRect(origin: .zero, size: size)
        hostingView.frame = frame
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        render()
    }
    func reveal(_ identifier: String) -> Bool {
        guard let marker = marker(for: identifier) else { return false }
        marker.scrollToVisible(marker.bounds)
        render()
        guard let scroll = marker.enclosingScrollView,
              let document = scroll.documentView else { return false }
        let rect = marker.convert(marker.bounds, to: document)
        let content = window.contentLayoutRect
        let screenContent = CGRect(origin: window.convertPoint(toScreen: content.origin), size: content.size)
        return !rect.isEmpty
            && scroll.documentVisibleRect.contains(rect)
            && screenContent.contains(marker.accessibilityFrame())
    }
    func render() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
    private func marker(for identifier: String) -> NSView? {
        allViews(hostingView).first { $0.accessibilityIdentifier() == identifier + ".marker" }
    }
    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
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
        NSApp.activate(ignoringOtherApps: true)
        render()
    }

    func clickRenderedControl(_ identifier: String) throws {
        render()
        let marker = try XCTUnwrap(
            view(for: identifier + ".marker"),
            "Missing control location marker: \(identifier)"
        )
        XCTAssertTrue(marker.window === window)
        XCTAssertFalse(marker.bounds.isEmpty)
        window.makeKey()
        let location = marker.convert(
            NSPoint(x: marker.bounds.midX, y: marker.bounds.midY),
            to: nil
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
            NSApp.sendEvent(event)
        }
        render()
    }

    func render() {
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
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

    func waitForRequest(timeout: TimeInterval = 1) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while requestsStarted == 0, Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        return requestsStarted > 0
    }

    func requestCount() -> Int { requestsStarted }

    func completeAll(with report: ProviderConnectionReport) {
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume(returning: report) }
    }
}
