import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class AIProviderSettingsRenderTests: XCTestCase {
    func testProviderSettingsHideUniversalASROptions() throws {
        let repository = RecordingProviderRepository(hasAPIKey: true)
        let defaultsSuite = "provider-hide-asr-(UUID().uuidString)"
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
        let host = ProviderSettingsProductionHost(
            model: appModel,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.selectSettingsSection("ai-provider")
        XCTAssertFalse(host.reveal(RecorderActionID.providerLanguage))
        XCTAssertFalse(host.reveal(RecorderActionID.providerPrompt))
        XCTAssertTrue(host.reveal(RecorderActionID.providerMeetingIntelligencePrompt))
    }

    func testPromptEditorsAreIndependentlyReachableAndLabeledAtSupportedSizes() throws {
        let repository = RecordingProviderRepository(hasAPIKey: true)
        let defaultsSuite = "provider-prompt-render-\(UUID().uuidString)"
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
        model.selectedProviderKind = .openAICompatible
        model.baseURLText = "https://api.example.com/v1"
        model.asrModel = "asr-model"
        model.llmModel = "llm-model"
        model.language = MeetingLanguage.cantonese.rawValue
        try assertPromptEditorSourceContract()

        for size in [
            CGSize(width: 860, height: 680),
            CGSize(width: 1_280, height: 800)
        ] {
            model.prompt = ""
            model.meetingIntelligencePrompt = ""
            let host = ProviderSettingsProductionHost(model: appModel, size: size)
            host.selectSettingsSection("ai-provider")
            defer { host.close() }

            XCTAssertTrue(host.reveal(RecorderActionID.providerPrompt))
            XCTAssertTrue(host.reveal(RecorderActionID.providerMeetingIntelligencePrompt))

            host.replaceTextEditor(RecorderActionID.providerPrompt, with: "asr guidance")
            assertSensitiveEqual(model.prompt, "asr guidance")
            assertSensitiveEqual(model.meetingIntelligencePrompt, "")

            host.replaceTextEditor(
                RecorderActionID.providerMeetingIntelligencePrompt,
                with: "meeting guidance"
            )
            assertSensitiveEqual(model.prompt, "asr guidance")
            assertSensitiveEqual(model.meetingIntelligencePrompt, "meeting guidance")
        }
    }

    func testPromptEditorSourceContractRejectsDetachedLabelAndMissingFrame() {
        let validSource = #"""
        Text("ASR Prompt")
            .font(.subheadline)
        Text("Optional transcription guidance sent only with future transcription jobs.")
            .font(.caption)
            .foregroundStyle(.secondary)
        TextEditor(text: $model.prompt)
            .accessibilityLabel("ASR Prompt")
            .providerAccessibility(RecorderActionID.providerPrompt)
            .frame(minHeight: 58, maxHeight: 96)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        Text("Meeting Intelligence Prompt")
            .font(.subheadline)
        Text("Optional guidance for future summaries and suggested titles. JSON output and transcript-safety requirements are always enforced.")
            .font(.caption)
            .foregroundStyle(.secondary)
        TextEditor(text: $model.meetingIntelligencePrompt)
            .accessibilityLabel("Meeting Intelligence Prompt")
            .providerAccessibility(RecorderActionID.providerMeetingIntelligencePrompt)
            .frame(minHeight: 58, maxHeight: 96)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }

        HStack(alignment: .center, spacing: 10) {
        """#
        let detachedLabelSource = validSource.replacingOccurrences(
            of: #"""
            TextEditor(text: $model.meetingIntelligencePrompt)
                .accessibilityLabel("Meeting Intelligence Prompt")
            """#,
            with: #"""
            Text("Detached label")
                .accessibilityLabel("Meeting Intelligence Prompt")
            TextEditor(text: $model.meetingIntelligencePrompt)
            """#
        )
        let missingFrameSource = validSource.replacingOccurrences(
            of: "    .frame(minHeight: 58, maxHeight: 96)\n    .overlay",
            with: "    .overlay",
            options: [],
            range: validSource.range(of: "TextEditor(text: $model.meetingIntelligencePrompt)")
                .map { $0.lowerBound..<validSource.endIndex }
        )
        let meetingIntelligenceHeader = [
            "Text(\"Meeting Intelligence Prompt\")",
            "    .font(.subheadline)",
            "Text(\"Optional guidance for future summaries and suggested titles. JSON output and transcript-safety requirements are always enforced.\")",
            "    .font(.caption)",
            "    .foregroundStyle(.secondary)"
        ].joined(separator: "\n")
        let swappedMeetingIntelligenceHeader = [
            "Text(\"Meeting Intelligence Prompt\")",
            "    .font(.caption)",
            "Text(\"Optional guidance for future summaries and suggested titles. JSON output and transcript-safety requirements are always enforced.\")",
            "    .font(.subheadline)",
            "    .foregroundStyle(.secondary)"
        ].joined(separator: "\n")
        let styleSwapSource = validSource.replacingOccurrences(
            of: meetingIntelligenceHeader,
            with: swappedMeetingIntelligenceHeader,
            options: [],
            range: validSource.range(of: "Text(\"Meeting Intelligence Prompt\")")
                .map { $0.lowerBound..<validSource.endIndex }
        )
        let orderedMeetingIntelligenceModifiers = [
            "    .accessibilityLabel(\"Meeting Intelligence Prompt\")",
            "    .providerAccessibility(RecorderActionID.providerMeetingIntelligencePrompt)",
            "    .frame(minHeight: 58, maxHeight: 96)"
        ].joined(separator: "\n")
        let reorderedMeetingIntelligenceModifiers = [
            "    .accessibilityLabel(\"Meeting Intelligence Prompt\")",
            "    .frame(minHeight: 58, maxHeight: 96)",
            "    .providerAccessibility(RecorderActionID.providerMeetingIntelligencePrompt)"
        ].joined(separator: "\n")
        let modifierReorderedSource = validSource.replacingOccurrences(
            of: orderedMeetingIntelligenceModifiers,
            with: reorderedMeetingIntelligenceModifiers,
            options: [],
            range: validSource.range(of: "TextEditor(text: $model.meetingIntelligencePrompt)")
                .map { $0.lowerBound..<validSource.endIndex }
        )
        let nestedLabelSource = validSource.replacingOccurrences(
            of: "    .accessibilityLabel(\"Meeting Intelligence Prompt\")",
            with: "    .background(Text(\"Nested view\").accessibilityLabel(\"Meeting Intelligence Prompt\"))",
            options: [],
            range: validSource.range(of: "TextEditor(text: $model.meetingIntelligencePrompt)")
                .map { $0.lowerBound..<validSource.endIndex }
        )

        XCTAssertTrue(
            PromptEditorSourceContract.matches(validSource),
            "Synthetic prompt editor contract fixture is invalid."
        )
        XCTAssertFalse(
            PromptEditorSourceContract.matches(detachedLabelSource),
            "Prompt editor source contract accepted an invalid mutation."
        )
        XCTAssertFalse(
            PromptEditorSourceContract.matches(missingFrameSource),
            "Prompt editor source contract accepted an invalid mutation."
        )
        XCTAssertFalse(
            PromptEditorSourceContract.matches(styleSwapSource),
            "Prompt editor source contract accepted an invalid mutation."
        )
        XCTAssertFalse(
            PromptEditorSourceContract.matches(modifierReorderedSource),
            "Prompt editor source contract accepted an invalid mutation."
        )
        XCTAssertFalse(
            PromptEditorSourceContract.matches(nestedLabelSource),
            "Prompt editor source contract accepted an invalid mutation."
        )
    }

    func testProviderColorSchemeIsLocallyDarkWithoutOverridingAdjacentLightSettingsContent() throws {
        let repository = RecordingProviderRepository(hasAPIKey: true)
        let model = makeConfiguredModel(repository: repository)
        let host = ProviderColorSchemeIsolationHost(model: model)
        defer { host.close() }

        XCTAssertEqual(
            host.appearance(for: RecorderSurfaceAppearance.providerDark.accessibilityIdentifier + ".marker"),
            .darkAqua
        )
        XCTAssertEqual(host.providerPickerAppearance, .darkAqua)
        XCTAssertEqual(host.appearance(for: "recorder.test.adjacent-settings"), .aqua)
    }

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
            host.selectSettingsSection("ai-provider")
            XCTAssertTrue(host.reveal(RecorderActionID.providerKind))
            XCTAssertTrue(host.reveal(
                RecorderSurfaceAppearance.providerDark.accessibilityIdentifier
            ))
            assertGenericProviderLocationsAreReachable(in: host)
            XCTAssertFalse(host.reveal(RecorderActionID.providerHKTGroupID))
            XCTAssertFalse(host.reveal(RecorderActionID.providerHKTResolvedURL))

            model.selectedProviderKind = .hktGenAI
            host.render()
            host.selectSettingsSection("ai-provider")
            XCTAssertTrue(host.reveal(RecorderActionID.providerKind))
            XCTAssertTrue(host.reveal(
                RecorderSurfaceAppearance.providerDark.accessibilityIdentifier
            ))
            XCTAssertTrue(host.reveal(RecorderActionID.providerHKTGroupID))
            XCTAssertTrue(host.reveal(RecorderActionID.providerHKTResolvedURL))
            XCTAssertFalse(host.reveal(RecorderActionID.providerBaseURL))
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
            RecorderActionID.providerMeetingIntelligencePrompt,
            RecorderActionID.providerSave,
            RecorderActionID.providerTest,
            RecorderActionID.providerRemoveKey,
            RecorderActionID.providerStatus
        ] {
            XCTAssertTrue(host.reveal(identifier), "Unreachable provider control: \(identifier)")
        }
    }

    private func assertSensitiveEqual<T: Equatable>(
        _ actual: @autoclosure () throws -> T,
        _ expected: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) rethrows {
        let actualValue = try actual()
        let expectedValue = try expected()
        guard actualValue == expectedValue else {
            XCTFail("Sensitive values did not match.", file: file, line: line)
            return
        }
    }

    private func assertPromptEditorSourceContract(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sourceURL = URL(fileURLWithPath: String(describing: file))
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RecorderApp/Views/AIProviderSettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        guard PromptEditorSourceContract.matches(source) else {
            XCTFail("Prompt editor source contract is incomplete.", file: file, line: line)
            return
        }
    }
}

private enum PromptEditorSourceContract {
    private static let asrTitle = #"Text("ASR Prompt")"#
    private static let asrHelp = #"Text("Optional transcription guidance sent only with future transcription jobs.")"#
    private static let meetingIntelligenceTitle = #"Text("Meeting Intelligence Prompt")"#
    private static let meetingIntelligenceHelp = #"Text("Optional guidance for future summaries and suggested titles. JSON output and transcript-safety requirements are always enforced.")"#
    private static let actionsBoundary = "HStack(alignment: .center, spacing: 10) {"
    private static let frame = ".frame(minHeight: 58, maxHeight: 96)"
    private static let overlay = ".overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))"

    private struct SourceLine {
        let text: String
        let indentation: Int
    }

    static func matches(_ source: String) -> Bool {
        let lines = normalizedLines(source)
        guard let asrTitleIndex = lines.firstIndex(where: { $0.text == asrTitle }) else {
            return false
        }
        let afterASRTitle = lines.index(after: asrTitleIndex)
        guard let meetingIntelligenceTitleIndex = lines[afterASRTitle...]
            .firstIndex(where: { $0.text == meetingIntelligenceTitle }) else {
            return false
        }
        let afterMeetingIntelligenceTitle = lines.index(after: meetingIntelligenceTitleIndex)
        guard let actionsBoundaryIndex = lines[afterMeetingIntelligenceTitle...]
            .firstIndex(where: { $0.text == actionsBoundary }) else {
            return false
        }

        let asrSection = Array(lines[asrTitleIndex..<meetingIntelligenceTitleIndex])
        let meetingIntelligenceSection = Array(
            lines[meetingIntelligenceTitleIndex..<actionsBoundaryIndex]
        )
        return matchesPromptSection(
            asrSection,
            title: asrTitle,
            help: asrHelp,
            binding: "TextEditor(text: $model.prompt)",
            accessibilityLabel: #".accessibilityLabel("ASR Prompt")"#,
            accessibilityIdentifier: ".providerAccessibility(RecorderActionID.providerPrompt)",
            expectsClosingBrace: false
        ) && matchesPromptSection(
            meetingIntelligenceSection,
            title: meetingIntelligenceTitle,
            help: meetingIntelligenceHelp,
            binding: "TextEditor(text: $model.meetingIntelligencePrompt)",
            accessibilityLabel: #".accessibilityLabel("Meeting Intelligence Prompt")"#,
            accessibilityIdentifier: ".providerAccessibility(RecorderActionID.providerMeetingIntelligencePrompt)",
            expectsClosingBrace: true
        )
    }

    private static func matchesPromptSection(
        _ section: [SourceLine],
        title: String,
        help: String,
        binding: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        expectsClosingBrace: Bool
    ) -> Bool {
        let expectedCore = [
            title,
            ".font(.subheadline)",
            help,
            ".font(.caption)",
            ".foregroundStyle(.secondary)",
            binding,
            accessibilityLabel,
            accessibilityIdentifier,
            frame,
            overlay
        ]
        let expectedCount = expectedCore.count + (expectsClosingBrace ? 1 : 0)
        guard section.count == expectedCount else { return false }

        let core = Array(section.prefix(expectedCore.count))
        guard core.map(\.text) == expectedCore else { return false }

        let baseIndentation = core[0].indentation
        let expectedIndentationDeltas = [0, 4, 0, 4, 4, 0, 4, 4, 4, 4]
        guard core.enumerated().allSatisfy({ index, line in
            line.indentation == baseIndentation + expectedIndentationDeltas[index]
        }) else {
            return false
        }

        return !expectsClosingBrace || section.last?.text == "}"
    }

    private static func normalizedLines(_ source: String) -> [SourceLine] {
        source.components(separatedBy: .newlines).compactMap { rawLine in
            let text = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let indentation = rawLine.prefix(while: { character in
                character == " " || character == "\t"
            }).reduce(into: 0) { count, character in
                count += character == "\t" ? 4 : 1
            }
            return SourceLine(text: text, indentation: indentation)
        }
    }
}

@MainActor
private final class ProviderColorSchemeIsolationHost {
    private let hostingView: NSHostingView<ProviderColorSchemeIsolationRoot>
    private let window: NSWindow

    init(model: AIProviderSettingsModel) {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 680)
        hostingView = NSHostingView(rootView: ProviderColorSchemeIsolationRoot(model: model))
        hostingView.frame = frame
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        render()
    }

    var providerPickerAppearance: NSAppearance.Name? {
        allViews(hostingView)
            .compactMap { $0 as? NSPopUpButton }
            .first?
            .effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua])
    }

    func appearance(for identifier: String) -> NSAppearance.Name? {
        guard let view = allViews(hostingView)
            .first(where: { $0.accessibilityIdentifier() == identifier }) else {
            return nil
        }
        return view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func render() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    private func allViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }
}

@MainActor
private struct ProviderColorSchemeIsolationRoot: View {
    @ObservedObject var model: AIProviderSettingsModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            AIProviderSettingsView(model: model)
                .frame(width: 520, alignment: .topLeading)
            VStack(alignment: .leading) {
                Text("Adjacent Settings")
                AppearanceProbe(identifier: "recorder.test.adjacent-settings")
                    .frame(width: 1, height: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
        }
    }
}

private struct AppearanceProbe: NSViewRepresentable {
    let identifier: String

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        view.setAccessibilityIdentifier(identifier)
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
        let isProviderSurface = identifier == RecorderSurfaceAppearance.providerDark.accessibilityIdentifier
        return !rect.isEmpty
            && (isProviderSurface
                ? scroll.documentVisibleRect.intersects(rect)
                : scroll.documentVisibleRect.contains(rect))
            && (isProviderSurface
                ? screenContent.intersects(marker.accessibilityFrame())
                : screenContent.contains(marker.accessibilityFrame()))
    }
    func render() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    func selectSettingsSection(_ section: String) {
        let identifier = "recorder.settings.navigation.\(section)"
        guard marker(for: identifier) != nil else {
            XCTFail("Missing settings navigation marker: \(identifier)")
            return
        }
        guard let settingsSection = RecorderSettingsSection(rawValue: section),
              let row = RecorderSettingsSection.allCases.firstIndex(of: settingsSection),
              let table = allViews(hostingView).compactMap({ $0 as? NSTableView }).first else {
            XCTFail("Missing native settings List for marker: \(identifier)")
            return
        }
        while table.selectedRow < row {
            guard sendSettingsRailKey(.downArrow, table: table) else { return }
        }
        while table.selectedRow > row {
            guard sendSettingsRailKey(.upArrow, table: table) else { return }
        }
        render()
    }

    private enum SettingsRailKey {
        case upArrow
        case downArrow

        var characters: String { self == .downArrow ? "\u{F701}" : "\u{F700}" }
        var keyCode: UInt16 { self == .downArrow ? 125 : 126 }
    }

    private func sendSettingsRailKey(_ key: SettingsRailKey, table: NSTableView) -> Bool {
        window.makeFirstResponder(table)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: key.characters,
            charactersIgnoringModifiers: key.characters,
            isARepeat: false,
            keyCode: key.keyCode
        ) else {
            XCTFail("Could not create settings navigation event")
            return false
        }
        window.sendEvent(event)
        render()
        return true
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    func replaceTextEditor(_ identifier: String, with text: String) {
        guard let marker = marker(for: identifier) else {
            XCTFail("Missing provider editor marker.")
            return
        }
        marker.scrollToVisible(marker.bounds)
        render()
        let targetFrame = hostingView.convert(marker.bounds, from: marker)
        guard let editor = allViews(hostingView)
            .compactMap({ $0 as? NSTextView })
            .first(where: { editor in
                let frame = hostingView.convert(editor.bounds, from: editor)
                return !frame.isEmpty && frame.intersects(targetFrame)
            })
        else {
            XCTFail("Missing provider text editor.")
            return
        }
        editor.string = text
        editor.didChangeText()
        render()
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
        let isEnabled = entry.isEnabled
        return Action(isEnabled: isEnabled, trigger: {
            guard isEnabled else { return }
            entry.trigger()
        })
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
