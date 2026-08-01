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

        try host.performRenderedControlAction(RecorderActionID.providerSave)
        XCTAssertEqual(repository.saveCount, 1, "Save must invoke the injected repository exactly once")

        try host.performRenderedControlAction(RecorderActionID.providerTest)
        let requestStarted = await client.waitForRequest()
        XCTAssertTrue(requestStarted)
        host.render()

        XCTAssertTrue(model.isTesting)
        try host.assertRenderedControlIsDisabled(RecorderActionID.providerTest)
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
    private let actionRegistry = ProviderSettingsRenderedActionRegistry()
    private let hostingView: NSHostingView<ProviderSettingsActionCaptureRoot>
    private let window: NSWindow

    init(model: AIProviderSettingsModel, size: CGSize) {
        hostingView = NSHostingView(rootView: ProviderSettingsActionCaptureRoot(
            model: model,
            actionRegistry: actionRegistry
        ))
        let frame = NSRect(origin: .zero, size: size)
        hostingView.frame = frame
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        render()
    }

    func performRenderedControlAction(_ identifier: String) throws {
        let action = try renderedAction(for: identifier)
        XCTAssertTrue(action.isEnabled, "Rendered control must be enabled: \(identifier)")
        action.trigger()
        render()
    }

    func assertRenderedControlIsDisabled(_ identifier: String) throws {
        let action = try renderedAction(for: identifier)
        XCTAssertFalse(action.isEnabled, "Rendered control must be disabled: \(identifier)")
        action.trigger()
        render()
    }

    private func renderedAction(
        for identifier: String
    ) throws -> ProviderSettingsRenderedActionRegistry.Action {
        render()
        let marker = try XCTUnwrap(
            view(for: identifier + ".marker"),
            "Missing control location marker: \(identifier)"
        )
        XCTAssertTrue(marker.window === window)
        XCTAssertFalse(marker.bounds.isEmpty)
        return try actionRegistry.action(overlapping: marker, in: hostingView)
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

@MainActor
private struct ProviderSettingsActionCaptureRoot: View {
    @ObservedObject var model: AIProviderSettingsModel
    let actionRegistry: ProviderSettingsRenderedActionRegistry

    var body: some View {
        AIProviderSettingsView(model: model)
            .buttonStyle(ProviderSettingsActionCaptureStyle(registry: actionRegistry))
    }
}

@MainActor
private struct ProviderSettingsActionCaptureStyle: PrimitiveButtonStyle {
    let registry: ProviderSettingsRenderedActionRegistry

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ProviderSettingsRenderedActionMarker(
                registry: registry,
                trigger: { configuration.trigger() }
            ))
    }
}

@MainActor
private struct ProviderSettingsRenderedActionMarker: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let registry: ProviderSettingsRenderedActionRegistry
    let trigger: () -> Void

    func makeNSView(context _: Context) -> ProviderSettingsRenderedActionMarkerView {
        let view = ProviderSettingsRenderedActionMarkerView(frame: .zero)
        registry.update(view, isEnabled: isEnabled, trigger: trigger)
        return view
    }

    func updateNSView(_ view: ProviderSettingsRenderedActionMarkerView, context _: Context) {
        registry.update(view, isEnabled: isEnabled, trigger: trigger)
    }

    static func dismantleNSView(
        _ view: ProviderSettingsRenderedActionMarkerView,
        coordinator _: Void
    ) {
        view.registry?.remove(view)
    }
}

@MainActor
private final class ProviderSettingsRenderedActionMarkerView: NSView {
    weak var registry: ProviderSettingsRenderedActionRegistry?
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

@MainActor
private final class ProviderSettingsRenderedActionRegistry {
    struct Action {
        let isEnabled: Bool
        let trigger: () -> Void
    }

    private final class Entry {
        weak var view: NSView?
        var isEnabled: Bool
        var trigger: () -> Void

        init(view: NSView, isEnabled: Bool, trigger: @escaping () -> Void) {
            self.view = view
            self.isEnabled = isEnabled
            self.trigger = trigger
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func update(
        _ view: ProviderSettingsRenderedActionMarkerView,
        isEnabled: Bool,
        trigger: @escaping () -> Void
    ) {
        view.registry = self
        let key = ObjectIdentifier(view)
        if let entry = entries[key] {
            entry.isEnabled = isEnabled
            entry.trigger = trigger
        } else {
            entries[key] = Entry(view: view, isEnabled: isEnabled, trigger: trigger)
        }
    }

    func remove(_ view: NSView) {
        entries.removeValue(forKey: ObjectIdentifier(view))
    }

    func action(overlapping marker: NSView, in host: NSView) throws -> Action {
        entries = entries.filter { $0.value.view != nil }
        let targetFrame = host.convert(marker.bounds, from: marker)
        let candidates = entries.values.compactMap { entry -> (Entry, CGFloat)? in
            guard let view = entry.view else { return nil }
            let frame = host.convert(view.bounds, from: view)
            guard frame.intersects(targetFrame), !frame.isEmpty else { return nil }
            let dx = frame.midX - targetFrame.midX
            let dy = frame.midY - targetFrame.midY
            return (entry, hypot(dx, dy))
        }
        XCTAssertEqual(candidates.count, 1, "Rendered control must overlap exactly one primitive action")
        guard let entry = candidates.min(by: { $0.1 < $1.1 })?.0 else {
            XCTFail("Rendered control has no captured primitive action")
            throw RenderedActionError.missingAction
        }
        return Action(isEnabled: entry.isEnabled, trigger: entry.trigger)
    }

    private enum RenderedActionError: Error { case missingAction }
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
