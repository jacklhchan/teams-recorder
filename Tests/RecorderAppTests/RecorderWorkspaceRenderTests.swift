import AppKit
import Combine
import SwiftUI
import XCTest
@testable import RecorderApp

private enum RecordingsSurfaceTestMarker {
    static let recordingsLight = RecorderSurfaceAppearance.recordingsLight.accessibilityIdentifier
    static let recordingsDark = RecorderSurfaceAppearance.recordingsDark.accessibilityIdentifier
    static let recordingsStatusLight = RecorderSurfaceAppearance.recordingsStatusLight.accessibilityIdentifier
    static let recordingsStatusDark = RecorderSurfaceAppearance.recordingsStatusDark.accessibilityIdentifier

    static func transcriptionCancel(_ rowID: String) -> String {
        "recorder.row.transcription-cancel.\(rowID)"
    }

    static func transcriptionLog(_ rowID: String) -> String {
        "recorder.row.transcription-log.\(rowID)"
    }
}

@MainActor
final class RecorderWorkspaceRenderTests: XCTestCase {
    func testDirectionARecordingsOpensCanonicalDetailAndFailsClosedWhenRemoved() throws {
        let fixture = try RecordingsMeetingIntelligenceRenderFixture()
        defer { fixture.remove() }
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680),
            systemColorScheme: .dark
        )
        defer { host.close() }
        host.select(.recordings)

        XCTAssertTrue(host.containsAccessibilityIdentifier(
            RecorderSurfaceAppearance.recordingsDark.accessibilityIdentifier
        ))
        let rowID = fixture.session.id.lastPathComponent
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(rowID)"))
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.transcript.\(rowID)"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.transcript.detail.root"))
        XCTAssertFalse(host.containsView(named: "AVPlayerView"))
        XCTAssertTrue(host.replaceTranscriptEditorText(with: "Unsaved route draft"))
        XCTAssertEqual(host.transcriptEditorText, "Unsaved route draft")
        fixture.model.libraryFeature.seedCanonicalSessionsForTesting(
            [], workspace: fixture.workspace, fence: .initial
        )
        host.render()
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.recordings.list"))
        XCTAssertFalse(host.containsAccessibilityIdentifier(RecorderActionID.saveTranscript))
        XCTAssertFalse(host.containsAccessibilityIdentifier(
            RecorderActionID.meetingIntelligenceCard
        ))
        XCTAssertFalse(host.containsView(named: "AVPlayerView"))
        XCTAssertFalse(host.containsView(named: "RecordingPlaybackView"))
        XCTAssertFalse(host.click(atAccessibilityFrame: "recorder.row.transcript.\(rowID)"))
        fixture.model.libraryFeature.seedCanonicalSessionsForTesting(
            [fixture.session], workspace: fixture.workspace, fence: .initial
        )
        host.render()
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(rowID)"))
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.transcript.\(rowID)"))
        try waitUntil(timeout: 1, message: "reopened detail to load original transcript") {
            host.transcriptEditorText == "Production recordings transcript"
        }
        XCTAssertFalse(host.containsView(named: "AVPlayerView"))
        XCTAssertFalse(host.containsView(named: "RecordingPlaybackView"))
    }

    func testRecordingsFollowsLightSystemAppearance() throws {
        try assertRecordingsFollowsSystemAppearance(
            .light,
            expectedNativeAppearance: .aqua,
            expectedRecordingsMarker: RecordingsSurfaceTestMarker.recordingsLight,
            expectedStatusMarker: RecordingsSurfaceTestMarker.recordingsStatusLight,
            expectedTranscriptMarker: RecorderSurfaceAppearance.transcriptLight
        )
    }

    func testRecordingsFollowsDarkSystemAppearance() throws {
        try assertRecordingsFollowsSystemAppearance(
            .dark,
            expectedNativeAppearance: .darkAqua,
            expectedRecordingsMarker: RecordingsSurfaceTestMarker.recordingsDark,
            expectedStatusMarker: RecordingsSurfaceTestMarker.recordingsStatusDark,
            expectedTranscriptMarker: RecorderSurfaceAppearance.transcriptDark
        )
    }

    private func assertRecordingsFollowsSystemAppearance(
        _ systemColorScheme: ColorScheme,
        expectedNativeAppearance: NSAppearance.Name,
        expectedRecordingsMarker: String,
        expectedStatusMarker: String,
        expectedTranscriptMarker: RecorderSurfaceAppearance
    ) throws {
        let fixture = try RecordingsMeetingIntelligenceRenderFixture()
        defer { fixture.remove() }
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800),
            systemColorScheme: systemColorScheme
        )
        defer { host.close() }

        host.select(.recordings)
        let rowID = fixture.session.id.lastPathComponent

        assertOnlyRecordingsMarker(host, expected: expectedRecordingsMarker)
        assertNoRecordingsStatusMarker(host)
        XCTAssertEqual(
            host.colorSchemeAppearance(for: "recorder.destination.recordings"),
            expectedNativeAppearance
        )
        XCTAssertEqual(
            host.nativeButtonColorSchemeAppearance(for: "recorder.row.card.\(rowID)"),
            expectedNativeAppearance
        )

        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(rowID)"))
        assertOnlyRecordingsMarker(host, expected: expectedRecordingsMarker)
        for identifier in [
            "recorder.row.play.\(rowID)",
            "recorder.row.open.\(rowID)",
            "recorder.row.edit.\(rowID)",
            "recorder.row.transcribe.\(rowID)",
            "recorder.row.trash.\(rowID)",
            "recorder.row.log.\(rowID)",
            RecorderActionID.openTranscript
        ] {
            XCTAssertEqual(
                host.nativeButtonColorSchemeAppearance(for: identifier),
                expectedNativeAppearance,
                "Expanded Recordings action must follow the system appearance: \(identifier)"
            )
        }

        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.edit.\(rowID)"))
        try waitUntil(timeout: 1, message: "metadata editor text fields to render") {
            host.nativeTextFieldColorSchemeAppearance(for: RecorderActionID.metadataTitle)
                == expectedNativeAppearance
                && host.nativeTextFieldColorSchemeAppearance(for: RecorderActionID.metadataTags)
                    == expectedNativeAppearance
        }
        XCTAssertEqual(
            host.nativeTextFieldColorSchemeAppearance(for: RecorderActionID.metadataTitle),
            expectedNativeAppearance
        )
        XCTAssertEqual(
            host.nativeTextFieldColorSchemeAppearance(for: RecorderActionID.metadataTags),
            expectedNativeAppearance
        )
        host.dismissSheets()

        fixture.model.transcriptionFeature.replaceLoadedStates([
            fixture.session.id: .init(
                phase: .completed,
                message: "Transcription finished",
                startedAt: .now,
                finishedAt: .now
            )
        ])
        let statusID = "recorder.row.transcription-status.\(rowID)"
        try waitUntil(timeout: 1, message: "successful transcription status to render") {
            host.containsAccessibilityIdentifier(statusID)
                && host.containsAccessibilityIdentifier(expectedStatusMarker)
        }
        assertOnlyRecordingsMarker(host, expected: expectedRecordingsMarker)
        assertOnlyRecordingsStatusMarker(host, expected: expectedStatusMarker)
        XCTAssertEqual(
            host.nativeButtonColorSchemeAppearance(
                for: RecordingsSurfaceTestMarker.transcriptionLog(rowID)
            ),
            expectedNativeAppearance
        )

        fixture.model.transcriptionFeature.replaceLoadedStates([
            fixture.session.id: .init(
                phase: .failed,
                message: "Transcription failed",
                startedAt: .now,
                finishedAt: .now
            )
        ])
        try waitUntil(timeout: 1, message: "failed transcription status to render") {
            host.containsAccessibilityIdentifier(statusID)
                && host.containsAccessibilityIdentifier(expectedStatusMarker)
                && fixture.model.transcriptionFeature.presentation
                    .transcriptionStatesBySessionID[fixture.session.id]?.message
                    == "Transcription failed"
        }
        assertOnlyRecordingsMarker(host, expected: expectedRecordingsMarker)
        assertOnlyRecordingsStatusMarker(host, expected: expectedStatusMarker)

        XCTAssertTrue(host.click(atAccessibilityFrame: RecorderActionID.openTranscript))
        XCTAssertTrue(host.containsAccessibilityIdentifier(
            expectedTranscriptMarker.accessibilityIdentifier
        ))
    }

    func testRecordingsAppearanceMarkersAtMinimumAndWideSizes() throws {
        let variants: [(ColorScheme, NSAppearance.Name, String, String)] = [
            (
                .light,
                .aqua,
                RecordingsSurfaceTestMarker.recordingsLight,
                RecordingsSurfaceTestMarker.recordingsStatusLight
            ),
            (
                .dark,
                .darkAqua,
                RecordingsSurfaceTestMarker.recordingsDark,
                RecordingsSurfaceTestMarker.recordingsStatusDark
            )
        ]
        let sizes = [
            CGSize(width: 860, height: 680),
            CGSize(width: 1_280, height: 800)
        ]

        for (
            systemColorScheme,
            expectedNativeAppearance,
            expectedMarker,
            expectedStatusMarker
        ) in variants {
            for size in sizes {
                try assertActiveRecordingsStatus(
                    at: size,
                    systemColorScheme: systemColorScheme,
                    expectedNativeAppearance: expectedNativeAppearance,
                    expectedRecordingsMarker: expectedMarker,
                    expectedStatusMarker: expectedStatusMarker
                )
            }
        }
    }

    private func assertActiveRecordingsStatus(
        at size: CGSize,
        systemColorScheme: ColorScheme,
        expectedNativeAppearance: NSAppearance.Name,
        expectedRecordingsMarker: String,
        expectedStatusMarker: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = try RecordingsMeetingIntelligenceRenderFixture()
        defer { fixture.remove() }
        fixture.model.transcriptionFeature.start(
            session: fixture.session,
            providerIsConfigured: true
        )
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: size,
            systemColorScheme: systemColorScheme
        )
        defer { host.close() }

        host.select(.recordings)
        let rowID = fixture.session.id.lastPathComponent
        let statusID = "recorder.row.transcription-status.\(rowID)"
        let cancelID = RecordingsSurfaceTestMarker.transcriptionCancel(rowID)
        let logID = RecordingsSurfaceTestMarker.transcriptionLog(rowID)
        XCTAssertTrue(
            host.click(atAccessibilityFrame: "recorder.row.card.\(rowID)"),
            file: file,
            line: line
        )
        fixture.model.transcriptionFeature.objectWillChange.send()
        host.render()
        try waitUntil(timeout: 1, message: "active transcription status to render") {
            host.containsAccessibilityIdentifier(statusID)
                && host.containsAccessibilityIdentifier(expectedStatusMarker)
        }
        XCTAssertTrue(
            host.revealSettingsControl(statusID),
            "Active status must be reachable at \(Int(size.width))x\(Int(size.height))",
            file: file,
            line: line
        )

        assertOnlyRecordingsMarker(
            host,
            expected: expectedRecordingsMarker,
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.colorSchemeAppearance(for: "recorder.destination.recordings"),
            expectedNativeAppearance,
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.nativeButtonColorSchemeAppearance(
                for: "recorder.row.card.\(rowID)"
            ),
            expectedNativeAppearance,
            file: file,
            line: line
        )
        assertOnlyRecordingsStatusMarker(
            host,
            expected: expectedStatusMarker,
            file: file,
            line: line
        )
        XCTAssertNil(
            host.accessibilityLabel(for: statusID),
            "Passive status marker must not duplicate the visible status label",
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.nativeButtonCount(for: cancelID),
            1,
            "Cancel must be one real NSButton with its per-row identifier",
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.nativeButtonCount(for: logID),
            1,
            "Status Log must be one real NSButton with its per-row identifier",
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.nonButtonAccessibilityIdentifierCount(cancelID),
            0,
            "Cancel identifier must not be carried by a fake marker view",
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.nonButtonAccessibilityIdentifierCount(logID),
            0,
            "Log identifier must not be carried by a fake marker view",
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.nativeButtonAccessibilityLabel(for: cancelID),
            "Cancel",
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.nativeButtonAccessibilityLabel(for: logID),
            "Open ASR log for \(fixture.session.displayName)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.nativeButtonColorSchemeAppearance(for: cancelID),
            expectedNativeAppearance,
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.nativeButtonColorSchemeAppearance(for: logID),
            expectedNativeAppearance,
            file: file,
            line: line
        )

        let statusFrame = try XCTUnwrap(
            host.frame(forAccessibilityIdentifier: statusID),
            "Missing active status frame",
            file: file,
            line: line
        )
        let cancelFrame = try XCTUnwrap(
            host.nativeButtonFrame(for: cancelID),
            "Missing real Cancel button frame",
            file: file,
            line: line
        )
        let logFrame = try XCTUnwrap(
            host.nativeButtonFrame(for: logID),
            "Missing real status Log button frame",
            file: file,
            line: line
        )
        for (name, frame) in [
            ("status", statusFrame),
            ("Cancel", cancelFrame),
            ("Log", logFrame)
        ] {
            XCTAssertTrue(
                host.visibleContentRect.contains(frame),
                "\(name) must stay inside the host at \(Int(size.width))x\(Int(size.height))",
                file: file,
                line: line
            )
            XCTAssertTrue(
                host.windowContentRect.contains(frame),
                "\(name) must stay inside the window at \(Int(size.width))x\(Int(size.height))",
                file: file,
                line: line
            )
        }

        let expectedLogStatus = "No ASR log found for \(fixture.session.displayName)"
        fixture.model.statusMessage = "Awaiting status Log action"
        var logCallbackCount = 0
        let logObserver = fixture.model.$statusMessage
            .dropFirst()
            .sink { message in
                if message == expectedLogStatus {
                    logCallbackCount += 1
                }
            }
        defer { logObserver.cancel() }
        XCTAssertTrue(
            host.pressNativeButton(for: logID),
            "Status Log action must be exercised through the real NSButton",
            file: file,
            line: line
        )
        XCTAssertEqual(fixture.model.statusMessage, expectedLogStatus, file: file, line: line)
        XCTAssertEqual(logCallbackCount, 1, file: file, line: line)

        XCTAssertEqual(
            fixture.model.transcriptionFeature.presentation.transcribingSessionID,
            fixture.session.id,
            file: file,
            line: line
        )
        XCTAssertTrue(
            host.pressNativeButton(for: cancelID),
            "Cancel action must be exercised through the real NSButton",
            file: file,
            line: line
        )
        try waitUntil(timeout: 1, message: "real Cancel button to settle active transcription") {
            let presentation = fixture.model.transcriptionFeature.presentation
            return presentation.transcribingSessionID == nil
                && presentation.transcriptionStatesBySessionID[fixture.session.id]?.phase
                    == .cancelled
        }
        XCTAssertEqual(
            fixture.model.transcriptionFeature.presentation
                .transcriptionStatesBySessionID[fixture.session.id]?.phase,
            .cancelled,
            file: file,
            line: line
        )
        XCTAssertEqual(logCallbackCount, 1, file: file, line: line)
    }

    private func assertOnlyRecordingsMarker(
        _ host: WorkspaceHost,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for marker in [
            RecordingsSurfaceTestMarker.recordingsLight,
            RecordingsSurfaceTestMarker.recordingsDark
        ] {
            XCTAssertEqual(
                host.containsAccessibilityIdentifier(marker),
                marker == expected,
                "Unexpected Recordings surface marker: \(marker)",
                file: file,
                line: line
            )
        }
    }

    private func assertNoRecordingsStatusMarker(
        _ host: WorkspaceHost,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            host.containsAccessibilityIdentifier(RecordingsSurfaceTestMarker.recordingsStatusLight),
            file: file,
            line: line
        )
        XCTAssertFalse(
            host.containsAccessibilityIdentifier(RecordingsSurfaceTestMarker.recordingsStatusDark),
            file: file,
            line: line
        )
    }

    private func assertOnlyRecordingsStatusMarker(
        _ host: WorkspaceHost,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for marker in [
            RecordingsSurfaceTestMarker.recordingsStatusLight,
            RecordingsSurfaceTestMarker.recordingsStatusDark
        ] {
            XCTAssertEqual(
                host.containsAccessibilityIdentifier(marker),
                marker == expected,
                "Unexpected Recordings status marker: \(marker)",
                file: file,
                line: line
            )
        }
    }

    func testDirectionARecordingsCardsAllowExactlyOneExpandedSession() throws {
        let fixture = try RecordingsMeetingIntelligenceRenderFixture()
        defer { fixture.remove() }
        let secondFolder = fixture.workspace.appendingPathComponent("second", isDirectory: true)
        let second = RecordingSession(
            id: secondFolder, folderURL: secondFolder,
            recordingURL: secondFolder.appendingPathComponent("recording.m4a"),
            createdAt: .now, duration: 20, fileSize: 1,
            metadata: .init(title: "Second recording")
        )
        fixture.model.libraryFeature.seedCanonicalSessionsForTesting(
            [fixture.session, second], workspace: fixture.workspace, fence: .initial
        )
        let host = try makeWorkspaceHost(model: fixture.model, size: .init(width: 860, height: 680))
        defer { host.close() }
        host.select(.recordings)
        let firstID = fixture.session.id.lastPathComponent
        let secondID = second.id.lastPathComponent
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.row.card.\(firstID)"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.row.card.\(secondID)"))
        XCTAssertEqual(host.accessibilityValue(for: "recorder.row.card.\(firstID)") as? String, "Collapsed")
        XCTAssertEqual(host.accessibilityValue(for: "recorder.row.card.\(secondID)") as? String, "Collapsed")
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.expanded.\(firstID)"))
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.expanded.\(secondID)"))
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(firstID)"))
        XCTAssertEqual(host.accessibilityValue(for: "recorder.row.card.\(firstID)") as? String, "Expanded")
        XCTAssertEqual(host.accessibilityValue(for: "recorder.row.card.\(secondID)") as? String, "Collapsed")
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.row.expanded.\(firstID)"))
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.expanded.\(secondID)"))
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(secondID)"))
        XCTAssertEqual(host.accessibilityValue(for: "recorder.row.card.\(firstID)") as? String, "Collapsed")
        XCTAssertEqual(host.accessibilityValue(for: "recorder.row.card.\(secondID)") as? String, "Expanded")
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.expanded.\(firstID)"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.row.expanded.\(secondID)"))
    }

    func testInFlightSaveCannotReopenInvalidatedRecordingsDetail() async throws {
        let mutationAttempt = DispatchSemaphore(value: 0)
        let releaseMutation = DispatchSemaphore(value: 0)
        let holderEntered = DispatchSemaphore(value: 0)
        let gate = RecordingSessionMutationGate {
            mutationAttempt.signal()
        }
        let fixture = try RecordingsMeetingIntelligenceRenderFixture(
            mutationGate: gate
        )
        defer {
            releaseMutation.signal()
            fixture.remove()
        }
        let folder = fixture.session.folderURL
        let holder = Task.detached {
            gate.withMutation(for: folder) {
                holderEntered.signal()
                releaseMutation.wait()
            }
        }
        XCTAssertEqual(holderEntered.wait(timeout: .now() + 1), .success)
        // Drain the holder's own mutation-attempt notification. The next
        // signal must come from the admitted transcript save waiting on the
        // same gate.
        try waitUntil(timeout: 1, message: "holder mutation notification") {
            mutationAttempt.wait(timeout: .now()) == .success
        }

        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }
        host.select(.recordings)
        let rowID = fixture.session.id.lastPathComponent
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(rowID)"))
        XCTAssertTrue(host.click(
            atAccessibilityFrame: "recorder.row.transcript.\(rowID)"
        ))
        XCTAssertTrue(host.containsAccessibilityIdentifier(
            "recorder.transcript.detail.root"
        ))
        XCTAssertTrue(host.replaceTranscriptEditorText(
            with: "Durable in-flight transcript"
        ))
        XCTAssertEqual(
            host.transcriptEditorText,
            "Durable in-flight transcript"
        )
        XCTAssertTrue(host.click(
            atAccessibilityFrame: RecorderActionID.saveTranscript
        ))
        await waitUntilAsync(timeout: 1, message: "transcript save to enter in-flight state") {
            host.containsAccessibilityIdentifier(
                RecorderActionID.transcriptSaveInFlight
            )
        }
        await waitUntilAsync(timeout: 1, message: "transcript save to wait on the shared gate") {
            mutationAttempt.wait(timeout: .now()) == .success
        }

        fixture.model.libraryFeature.seedCanonicalSessionsForTesting(
            [], workspace: fixture.workspace, fence: .initial
        )
        host.render()
        await waitUntilAsync(timeout: 1, message: "removed session to close transcript detail") {
            host.containsAccessibilityIdentifier("recorder.recordings.list")
                && !host.containsAccessibilityIdentifier(
                    "recorder.transcript.detail.root"
                )
        }
        XCTAssertFalse(host.containsAccessibilityIdentifier(
            RecorderActionID.meetingIntelligenceCard
        ))

        releaseMutation.signal()
        await holder.value
        await waitUntilAsync(timeout: 2, message: "admitted transcript write to become durable") {
            (try? TranscriptDocumentStore.read(in: folder))
                == "Durable in-flight transcript"
        }
        XCTAssertTrue(host.containsAccessibilityIdentifier(
            "recorder.recordings.list"
        ))
        XCTAssertFalse(host.containsAccessibilityIdentifier(
            "recorder.transcript.detail.root"
        ))

        fixture.model.libraryFeature.seedCanonicalSessionsForTesting(
            [fixture.session], workspace: fixture.workspace, fence: .initial
        )
        host.render()
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(rowID)"))
        XCTAssertTrue(host.click(
            atAccessibilityFrame: "recorder.row.transcript.\(rowID)"
        ))
        await waitUntilAsync(timeout: 1, message: "reopened detail to load durable transcript") {
            host.transcriptEditorText
                == (try? TranscriptDocumentStore.read(in: folder))
        }
    }
    func testDirectionASidebarRendersAtSupportedSizes() throws {
        for size in [
            CGSize(width: 860, height: 680),
            CGSize(width: 1_280, height: 800)
        ] {
            let fixture = makeStartupDisabledFixture()
            let host = try makeWorkspaceHost(model: fixture.model, size: size)
            defer { host.close() }

            for identifier in [
                "recorder.workspace.sidebar",
                "recorder.sidebar.brand",
                "recorder.sidebar.storage",
                "recorder.navigation.record",
                "recorder.navigation.recordings",
                "recorder.navigation.settings"
            ] {
                let frame = try XCTUnwrap(
                    host.frame(forAccessibilityIdentifier: identifier),
                    "Missing Direction A sidebar element: \(identifier)"
                )
                XCTAssertTrue(host.windowContentRect.contains(frame))
            }
        }
    }

    func testDirectionASidebarUsesNativeGlassFallbackAndContrastMarkers() throws {
        let variants: [(Bool, ColorSchemeContrast, String, String)] = [
            (false, .standard,
             "recorder.glass.native", "recorder.surface.contrast.standard"),
            (true, .increased,
             "recorder.glass.material-separator",
             "recorder.surface.contrast.increased")
        ]
        for (reduceTransparency, contrast, glassID, contrastID) in variants {
            let fixture = makeStartupDisabledFixture()
            let host = try WorkspaceHost(
                model: fixture.model,
                size: .init(width: 860, height: 680),
                reduceTransparencyOverride: reduceTransparency,
                contrast: contrast
            )
            defer { host.close() }
            XCTAssertTrue(host.containsAccessibilityIdentifier(glassID))
            XCTAssertTrue(host.containsAccessibilityIdentifier(contrastID))
        }
    }

    func testNavigationShellStartsOnRecordAndCanRenderBaselineDestinations() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.destination.record"))
        host.select(.recordings)
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.destination.recordings"))
        host.select(.settings)
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.destination.settings"))
    }

    func testMinimumWorkspaceRepeatsEveryDestinationWithoutPendingRoute() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        for _ in 0 ..< 3 {
            for destination in RecorderDestination.allCases {
                host.select(destination)
                let identifier = "recorder.destination.\(destination.rawValue)"
                try waitUntil(timeout: 1) {
                    guard let frame = host.frame(
                        forAccessibilityIdentifier: identifier
                    ) else { return false }
                    return !frame.isEmpty
                }
                let frame = try XCTUnwrap(
                    host.frame(forAccessibilityIdentifier: identifier),
                    "Missing destination marker after repeat navigation: \(identifier)"
                )
                XCTAssertFalse(frame.isEmpty)
                XCTAssertTrue(
                    host.windowContentRect.contains(frame),
                    "\(identifier) must remain inside the 860×680 workspace: \(frame)."
                )
                XCTAssertEqual(host.navigationState.selection, destination)
                XCTAssertNil(host.navigationState.pendingDestination)
                for identifier in [
                    "recorder.sidebar.brand",
                    "recorder.sidebar.storage"
                ] {
                    XCTAssertEqual(
                        host.accessibilityIdentifierCount(identifier),
                        1,
                        "\(identifier) must remain unique after repeat navigation."
                    )
                }
            }
        }
    }

    func testSidebarVisibilityChangesPreserveRecordingsSelection() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.recordings)
        XCTAssertTrue(
            host.containsAccessibilityIdentifier(
                "recorder.destination.recordings"
            )
        )
        let visibleSidebarFrame = try XCTUnwrap(
            host.frame(forAccessibilityIdentifier: "recorder.workspace.sidebar")
        )
        XCTAssertFalse(visibleSidebarFrame.isEmpty)
        let expandedDetailFrame = try XCTUnwrap(
            host.frame(forAccessibilityIdentifier: "recorder.destination.recordings")
        )

        host.setColumnVisibility(.detailOnly)
        try waitUntil(timeout: 1) {
            guard let frame = host.frame(
                forAccessibilityIdentifier: "recorder.destination.recordings"
            ) else {
                return false
            }
            return frame.minX < expandedDetailFrame.minX
        }
        XCTAssertEqual(host.navigationState.selection, .recordings)
        XCTAssertTrue(
            host.containsAccessibilityIdentifier(
                "recorder.destination.recordings"
            )
        )

        let collapsedDetailFrame = try XCTUnwrap(
            host.frame(forAccessibilityIdentifier: "recorder.destination.recordings")
        )
        host.setColumnVisibility(.all)
        try waitUntil(timeout: 1) {
            guard let frame = host.frame(
                forAccessibilityIdentifier: "recorder.destination.recordings"
            ) else {
                return false
            }
            return frame.minX > collapsedDetailFrame.minX
        }
        XCTAssertEqual(host.navigationState.selection, .recordings)
    }

    func testMinimumWindowRendersRecordStatusAndPrimaryAction() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        for identifier in [
            "recorder.workspace.sidebar",
            "record-state",
            "elapsed-time",
            RecorderActionID.startStop,
            "system-meter",
            "microphone-meter",
            "capture-health"
        ] {
            XCTAssertTrue(
                host.containsAccessibilityIdentifier(identifier),
                "Missing minimum-window control: \(identifier)"
            )
        }
    }

    func testWideWindowRendersEveryDestinationOnce() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1280, height: 800)
        )
        defer { host.close() }

        for destination in RecorderDestination.allCases {
            host.select(destination)
            let identifier = "recorder.destination.\(destination.rawValue)"
            try waitUntil(timeout: 1) {
                guard let frame = host.frame(
                    forAccessibilityIdentifier: identifier
                ) else { return false }
                return !frame.isEmpty
            }
            let frame = try XCTUnwrap(
                host.frame(forAccessibilityIdentifier: identifier),
                "Missing wide destination marker: \(identifier)"
            )
            XCTAssertFalse(frame.isEmpty)
            XCTAssertTrue(
                host.windowContentRect.contains(frame),
                "\(identifier) must remain inside the wide workspace."
            )
        }
    }

    func testUnavailableCapturePermissionsExposeSettingsRecovery() throws {
        let cases: [
            (CapturePermissionState, CapturePermissionState)
        ] = [
            (CapturePermissionState.denied, .granted),
            (.restricted, .granted),
            (.granted, .restricted)
        ]
        for (systemPermission, microphonePermission) in cases {
            try assertVisibleSettingsRecoveryDeepLink(
                for: makeStartupDisabledFixture(
                    systemPermission: systemPermission,
                    microphonePermission: microphonePermission
                )
            )
        }
    }

    func testRecordingsRendersSessionSpecificActions() throws {
        let fixture = makeFixtureWithOneSession()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.recordings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(fixture.session.id.lastPathComponent)"))

        XCTAssertTrue(host.containsAccessibilityLabel("Play \(fixture.session.displayName)"))
        XCTAssertTrue(host.containsAccessibilityLabel("Edit details for \(fixture.session.displayName)"))
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.openTranscript))
        let rowID = fixture.session.id.lastPathComponent
        for identifier in [
            "recorder.row.play.\(rowID)",
            "recorder.row.open.\(rowID)",
            "recorder.row.edit.\(rowID)",
            "recorder.row.transcribe.\(rowID)",
            "recorder.row.transcript.\(rowID)",
            "recorder.row.trash.\(rowID)",
            "recorder.row.log.\(rowID)"
        ] {
            let frame = try XCTUnwrap(
                host.frame(forAccessibilityIdentifier: identifier),
                "Missing wide-layout session action: \(identifier)"
            )
            XCTAssertTrue(
                host.windowContentRect.contains(frame),
                "\(identifier) must remain inside the 1280×800 window"
            )
        }
    }

    func testMinimumRecordingsKeepsSessionActionsInsideWindow() throws {
        let fixture = makeFixtureWithOneSession()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.recordings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(fixture.session.id.lastPathComponent)"))

        let rowID = fixture.session.id.lastPathComponent
        for identifier in [
            "recorder.row.play.\(rowID)",
            "recorder.row.open.\(rowID)",
            "recorder.row.edit.\(rowID)",
            "recorder.row.transcribe.\(rowID)",
            "recorder.row.transcript.\(rowID)",
            "recorder.row.trash.\(rowID)",
            "recorder.row.log.\(rowID)"
        ] {
            let frame = try XCTUnwrap(
                host.frame(forAccessibilityIdentifier: identifier),
                "Missing session action: \(identifier)"
            )
            XCTAssertTrue(
                host.windowContentRect.contains(frame),
                "\(identifier) must remain inside the 860×680 window"
            )
        }
    }

    func testSessionActionMarkersUpdateWhenMetadataProjectionRenamesSameSession() throws {
        let fixture = makeFixtureWithOneSession()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.recordings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(fixture.session.id.lastPathComponent)"))
        let originalName = fixture.session.displayName
        let renamedName = "Renamed workspace recording"
        XCTAssertTrue(host.containsAccessibilityLabel("Play \(originalName)"))
        XCTAssertTrue(host.containsAccessibilityLabel("Edit details for \(originalName)"))

        fixture.model.seedLibrarySessionsForTesting([
            RecordingSession(
                id: fixture.session.id,
                folderURL: fixture.session.folderURL,
                recordingURL: fixture.session.recordingURL,
                createdAt: fixture.session.createdAt,
                duration: fixture.session.duration,
                fileSize: fixture.session.fileSize,
                metadata: .init(title: renamedName),
                searchDocument: fixture.session.searchDocument
            )
        ])
        host.render()

        XCTAssertTrue(host.containsAccessibilityLabel("Play \(renamedName)"))
        XCTAssertTrue(host.containsAccessibilityLabel("Edit details for \(renamedName)"))
        XCTAssertFalse(host.containsAccessibilityLabel("Play \(originalName)"))
        XCTAssertFalse(host.containsAccessibilityLabel("Edit details for \(originalName)"))
    }

    func testRecordingsRendersDirectLibraryFeatureSnapshotWithoutAppModelRelay() throws {
        let fixture = makeFixtureWithOneSession()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }
        host.select(.recordings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(fixture.session.id.lastPathComponent)"))

        var appModelChanges = 0
        let appModelChange = fixture.model.objectWillChange.sink { _ in
            appModelChanges += 1
        }
        defer { appModelChange.cancel() }

        let renamed = RecordingSession(
            id: fixture.session.id,
            folderURL: fixture.session.folderURL,
            recordingURL: fixture.session.recordingURL,
            createdAt: fixture.session.createdAt,
            duration: fixture.session.duration,
            fileSize: fixture.session.fileSize,
            metadata: .init(title: "Library feature publication"),
            searchDocument: fixture.session.searchDocument
        )
        fixture.model.libraryFeature.seedCanonicalSessionsForTesting(
            [renamed],
            workspace: fixture.model.outputFolder,
            fence: .initial
        )

        try waitUntil(timeout: 1) {
            host.containsAccessibilityLabel("Play Library feature publication")
        }
        XCTAssertFalse(host.containsAccessibilityLabel("Play \(fixture.session.displayName)"))
        XCTAssertEqual(
            appModelChanges,
            0,
            "Recordings must observe LibraryFeatureModel, not AppModel.objectWillChange."
        )
    }

    func testRecordingsRendersDirectTranscriptionFeatureProjectionWithoutAppModelRelay() throws {
        let fixture = makeFixtureWithOneSession()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680),
            systemColorScheme: .dark
        )
        defer { host.close() }
        host.select(.recordings)
        XCTAssertTrue(host.click(
            atAccessibilityFrame: "recorder.row.card.\(fixture.session.id.lastPathComponent)"
        ))

        var appModelChanges = 0
        let appModelChange = fixture.model.objectWillChange.sink { _ in
            appModelChanges += 1
        }
        defer { appModelChange.cancel() }

        let message = "Feature projection ready"
        fixture.model.transcriptionFeature.replaceLoadedStates([
            fixture.session.id: .init(
                phase: .completed,
                message: message,
                startedAt: .now,
                finishedAt: .now
            )
        ])

        let statusIdentifier =
            "recorder.row.transcription-status.\(fixture.session.id.lastPathComponent)"
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier(statusIdentifier)
                && fixture.model.transcriptionFeature.presentation
                    .transcriptionStatesBySessionID[fixture.session.id]?.message
                    == message
        }
        XCTAssertNil(host.accessibilityLabel(for: statusIdentifier))
        XCTAssertTrue(host.containsAccessibilityIdentifier(
            "recorder.surface.recordings.status.dark"
        ))
        XCTAssertEqual(
            appModelChanges,
            0,
            "Recordings must observe TranscriptionFeatureModel, not AppModel.objectWillChange."
        )
        XCTAssertFalse(host.containsView(named: "AVPlayerView"))
        XCTAssertFalse(host.containsView(named: "RecordingPlaybackView"))
    }

    func testTranscriptDetailActionProjectionUsesResolvedSessionForOpenDetail() {
        let folder = URL(fileURLWithPath: "/tmp/transcript-detail-action-\(UUID().uuidString)")
        let opened = RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 12,
            fileSize: 0,
            metadata: .init(title: "Original recording title", isFavorite: false)
        )
        let resolved = RecordingSession(
            id: opened.id,
            folderURL: opened.folderURL,
            recordingURL: opened.recordingURL,
            createdAt: opened.createdAt,
            duration: opened.duration,
            fileSize: opened.fileSize,
            metadata: .init(title: "Generated meeting title", isFavorite: true)
        )
        let visibleSessions: [RecordingSession] = []
        let allSessions = [resolved]
        XCTAssertTrue(visibleSessions.isEmpty)

        let current = TranscriptDetailActionProjection.current(
            opened: opened,
            allSessions: allSessions
        )

        XCTAssertEqual(current.id, opened.id)
        XCTAssertEqual(current.displayName, "Generated meeting title")
        XCTAssertTrue(current.isFavorite)
    }

    func testMeetingIntelligenceEditRouteUsesCurrentCanonicalSessionAndRejectsStaleOrForgedRequests() async {
        func makeSession(folder: URL, title: String) -> RecordingSession {
            .init(
                id: folder,
                folderURL: folder,
                recordingURL: folder.appendingPathComponent("recording.m4a"),
                createdAt: .distantPast,
                duration: 1,
                fileSize: 1,
                metadata: .init(title: title)
            )
        }

        let folder = URL(fileURLWithPath: "/tmp/mi-edit-route-\(UUID().uuidString)")
        let openedAlias = makeSession(folder: folder, title: "Old captured title")
        let canonical = makeSession(folder: folder, title: "Current canonical title")
        let switchedSession = makeSession(
            folder: URL(fileURLWithPath: "/tmp/mi-edit-route-switched-\(UUID().uuidString)"),
            title: "Switched session"
        )
        let forgedSession = makeSession(
            folder: URL(fileURLWithPath: "/tmp/mi-edit-route-forged-\(UUID().uuidString)"),
            title: "Forged session"
        )
        let artifact = MeetingIntelligenceArtifact(
            schemaVersion: MeetingIntelligenceArtifact.currentSchemaVersion,
            summary: "Captured summary",
            suggestedTitle: "Captured suggested title",
            sourceTranscriptSHA256: "sha256:" + String(repeating: "f", count: 64),
            sourceTranscriptByteCount: 12,
            model: "test-model",
            generatedAt: Date(timeIntervalSince1970: 1),
            intent: .generate,
            contentOrigin: .generated,
            editedAt: nil
        )
        var currentSessions = [canonical]
        let admission = RecordingsCanonicalActionAdmission {
            currentSessions
        }
        let capture = WorkspaceMeetingIntelligenceSaveCapture()

        let accepted = await RecordingsLibraryMeetingIntelligenceRouting.saveEdit(
            requestedSession: openedAlias,
            admission: admission,
            capturedArtifact: artifact,
            summary: "Edited summary",
            suggestedTitle: "Edited suggested title",
            save: { session, artifact, summary, suggestedTitle in
                await capture.save(
                    session: session,
                    artifact: artifact,
                    summary: summary,
                    suggestedTitle: suggestedTitle
                )
            }
        )

        XCTAssertEqual(accepted, .saved(artifact))
        XCTAssertEqual(
            capture.requests,
            [
                .init(
                    session: canonical,
                    artifact: artifact,
                    summary: "Edited summary",
                    suggestedTitle: "Edited suggested title"
                )
            ]
        )

        currentSessions = [switchedSession]
        let switched = await RecordingsLibraryMeetingIntelligenceRouting.saveEdit(
            requestedSession: openedAlias,
            admission: admission,
            capturedArtifact: artifact,
            summary: "Should be rejected",
            suggestedTitle: "Should be rejected",
            save: { session, artifact, summary, suggestedTitle in
                await capture.save(
                    session: session,
                    artifact: artifact,
                    summary: summary,
                    suggestedTitle: suggestedTitle
                )
            }
        )
        if case .conflict("The recording is no longer available.") = switched {
            // Expected: the old detail callback cannot cross a session switch.
        } else {
            XCTFail("A session-switched edit must be rejected before the AppModel wrapper.")
        }

        currentSessions = [canonical]
        let forged = await RecordingsLibraryMeetingIntelligenceRouting.saveEdit(
            requestedSession: forgedSession,
            admission: admission,
            capturedArtifact: artifact,
            summary: "Forged summary",
            suggestedTitle: "Forged title",
            save: { session, artifact, summary, suggestedTitle in
                await capture.save(
                    session: session,
                    artifact: artifact,
                    summary: summary,
                    suggestedTitle: suggestedTitle
                )
            }
        )
        if case .conflict("The recording is no longer available.") = forged {
            // Expected: forged IDs never reach AppModel.saveMeetingIntelligenceEdit.
        } else {
            XCTFail("A forged session must be rejected before the AppModel wrapper.")
        }
        XCTAssertEqual(capture.requests.count, 1)
    }

    func testProductionRecordingsEditAccessibilityPathSendsCapturedArtifactAndDraftsExactlyOnce() async throws {
        let editorEntered = expectation(description: "production edit reached artifact editor")
        let editor = RenderMeetingIntelligenceEditSpy(entered: editorEntered)
        let fixture = try RecordingsMeetingIntelligenceRenderFixture(artifactEditor: editor)
        defer { fixture.remove() }
        fixture.feature.reload(sessions: [fixture.session])
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: fixture.session.id)

        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.recordings)
        XCTAssertTrue(host.click(
            atAccessibilityFrame: "recorder.row.card.\(fixture.session.id.lastPathComponent)"
        ))
        XCTAssertTrue(host.click(
            atAccessibilityFrame: "recorder.row.transcript.\(fixture.session.id.lastPathComponent)"
        ))
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier("recorder.transcript.detail.root")
                && host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceGenerate)
        }

        XCTAssertTrue(host.click(atAccessibilityFrame: RecorderActionID.meetingIntelligenceGenerate))
        await fulfillment(of: [fixture.generatorEntered], timeout: 1)
        await fixture.generationGate.release()
        await fulfillment(of: [fixture.generatorFinished, fixture.published], timeout: 1)
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: fixture.session.id)
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceSummary)
                && host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceSuggestedTitle)
                && host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceEdit)
        }

        let capturedArtifact = try XCTUnwrap(
            fixture.feature.presentation(for: fixture.session).editableContent?.artifact
        )
        XCTAssertTrue(host.click(atAccessibilityFrame: RecorderActionID.meetingIntelligenceEdit))
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceEditSummary)
                && host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceEditSuggestedTitle)
                && host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceEditSave)
        }

        func allViews(startingAt view: NSView?) -> [NSView] {
            guard let view else { return [] }
            return [view] + view.subviews.flatMap { allViews(startingAt: $0) }
        }

        let renderedViews = NSApp.windows.flatMap { allViews(startingAt: $0.contentView) }
        func accessibilityFrame(for identifier: String) -> CGRect? {
            renderedViews.first { $0.accessibilityIdentifier() == identifier }?.accessibilityFrame()
        }

        func setAccessibilityValue(
            _ value: String,
            for identifier: String,
            replacing currentValue: String,
            expectedRole: NSAccessibility.Role?
        ) throws {
            let markerFrame = try XCTUnwrap(
                accessibilityFrame(for: identifier),
                "Missing rendered accessibility marker: \(identifier)"
            )
            let control = try XCTUnwrap(
                renderedViews.first { view in
                    guard markerFrame.intersects(view.accessibilityFrame()),
                          view.accessibilityValue() as? String == currentValue else {
                        return false
                    }
                    if let expectedRole {
                        return view.accessibilityRole() == expectedRole
                    }
                    return true
                },
                "The rendered \(identifier) marker must resolve to an accessibility value control."
            )
            if let expectedRole {
                XCTAssertEqual(
                    control.accessibilityRole(),
                    expectedRole,
                    "identifier=\(identifier) value=\(String(describing: control.accessibilityValue()))"
                )
            }
            func insertThroughTextInputClient(_ text: NSText) throws {
                text.window?.makeFirstResponder(text)
                let inputClient = try XCTUnwrap(
                    text as? any NSTextInputClient,
                    "The accessibility-resolved text control must accept text input."
                )
                inputClient.insertText(
                    value,
                    replacementRange: NSRange(location: 0, length: (text.string as NSString).length)
                )
            }

            if let nativeControl = control as? NSControl {
                nativeControl.window?.makeFirstResponder(nativeControl)
                let editor = try XCTUnwrap(
                    nativeControl.currentEditor(),
                    "The accessibility-resolved control must expose its AppKit field editor."
                )
                try insertThroughTextInputClient(editor)
                nativeControl.window?.endEditing(for: nativeControl)
            } else if let text = control as? NSText {
                try insertThroughTextInputClient(text)
            } else {
                control.setAccessibilityValue(value)
            }
            host.render()
            XCTAssertEqual(
                control.accessibilityValue() as? String,
                value,
                "identifier=\(identifier) role=\(String(describing: control.accessibilityRole()))"
            )
        }

        try setAccessibilityValue(
            "Production UI edited summary",
            for: RecorderActionID.meetingIntelligenceEditSummary,
            replacing: capturedArtifact.summary,
            expectedRole: NSAccessibility.Role.textArea
        )
        try setAccessibilityValue(
            "Production UI edited title",
            for: RecorderActionID.meetingIntelligenceEditSuggestedTitle,
            replacing: capturedArtifact.suggestedTitle,
            expectedRole: nil
        )
        host.render()

        XCTAssertTrue(host.click(atAccessibilityFrame: RecorderActionID.meetingIntelligenceEditSave))
        XCTAssertTrue(host.click(atAccessibilityFrame: RecorderActionID.meetingIntelligenceEditSave))
        await fulfillment(of: [editorEntered], timeout: 1)

        XCTAssertEqual(editor.requests.count, 1)
        XCTAssertEqual(editor.requests[0].capturedArtifact, capturedArtifact)
        XCTAssertEqual(editor.requests[0].summary, "Production UI edited summary")
        XCTAssertEqual(editor.requests[0].suggestedTitle, "Production UI edited title")

        await editor.release()
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: fixture.session.id)
    }

    func testRecordingsSheetObservesMeetingIntelligenceFeatureSnapshotWithoutAppModelRelay() async throws {
        let fixture = try RecordingsMeetingIntelligenceRenderFixture()
        defer { fixture.remove() }
        fixture.feature.reload(sessions: [fixture.session])
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: fixture.session.id)

        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }
        host.select(.recordings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(fixture.session.id.lastPathComponent)"))

        XCTAssertTrue(
            host.click(
                atAccessibilityFrame: "recorder.row.transcript.\(fixture.session.id.lastPathComponent)"
            ),
            "The actual RecordingsLibraryView transcript route must open its detail sheet."
        )
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier("recorder.transcript.detail.root")
        }
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceGenerate))
        XCTAssertFalse(host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceSuggestedTitle))
        XCTAssertFalse(host.containsView(named: "AVPlayerView"))

        var appModelChanges = 0
        let appModelChange = fixture.model.objectWillChange.sink { _ in
            appModelChanges += 1
        }
        defer { appModelChange.cancel() }

        fixture.feature.generate(for: fixture.session)
        await fulfillment(of: [fixture.generatorEntered], timeout: 1)
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceCancel)
                && host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceStatus)
        }

        await fixture.generationGate.release()
        await fulfillment(of: [fixture.generatorFinished, fixture.published], timeout: 1)
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: fixture.session.id)
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceSummary)
                && host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceSuggestedTitle)
                && !host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceCancel)
        }

        XCTAssertTrue(host.containsAccessibilityLabel("Generated title"))
        XCTAssertFalse(host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceCancel))
        XCTAssertEqual(
            appModelChanges,
            0,
            "The open production sheet must refresh from MeetingIntelligenceFeatureModel, not AppModel.objectWillChange."
        )
        XCTAssertFalse(host.containsView(named: "AVPlayerView"))
        XCTAssertFalse(host.containsView(named: "RecordingPlaybackView"))
    }

    func testSettingsRendersExistingCaptureTeamsVirtualMicAndProviderSections() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.settings)

        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.destination.settings"))
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.audio"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.settings.capture-section"))
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.recording"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("capture-mode-picker"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("teams-auto-recording-toggle"))
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.audio"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.settings.audio-integration-section"))
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.ai-provider"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.settings.transcription-section"))
    }

    func testMinimumSettingsRendersCaptureAndTeamsControls() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.settings)

        XCTAssertTrue(
            host.containsAccessibilityIdentifier("recorder.destination.settings")
        )
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.recording"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("capture-mode-picker"))
        XCTAssertTrue(
            host.containsAccessibilityIdentifier("teams-auto-recording-toggle")
        )
    }

    func testMinimumSettingsKeepsReadyTeamsStatusInsideWindow() throws {
        let fixture = makeReadyTeamsFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.settings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.recording"))

        let frame = try XCTUnwrap(
            host.frame(
                forAccessibilityIdentifier: "teams-mute-sync-status"
            ),
            "Missing Teams mute-sync status"
        )
        XCTAssertTrue(
            host.windowContentRect.contains(frame),
            "Ready Teams status must remain inside the 860×680 window: \(frame)"
        )
    }

    func testSourceControlGatesRemainDisabledDuringLifecycleWork() throws {
        let fixture = makeLifecycleWorkingFixture()
        defer { fixture.source.resumeRefresh() }
        fixture.model.refreshCaptureApplications()
        try waitUntil(timeout: 1) { fixture.source.refreshStarted }
        XCTAssertTrue(fixture.model.isCaptureLifecycleWorking)

        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }
        host.select(.settings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.recording"))

        XCTAssertFalse(try host.isEnabled("capture-mode-picker"))
        XCTAssertFalse(try host.isEnabled("recorder.settings.capture-application-picker"))
        XCTAssertFalse(try host.isEnabled("recorder.settings.capture-refresh"))
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.audio"))
        XCTAssertFalse(try host.isEnabled("recorder.settings.microphone-picker"))
    }

    func testDirectionASettingsKeepsEveryExistingControlReachable() throws {
        let fixture = makeStartupDisabledFixture(
            systemPermission: .granted,
            microphonePermission: .granted
        )
        fixture.model.captureSelection = .init(
            mode: .selectedApplication,
            selectedBundleIdentifier: "com.example.capture"
        )
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }
        host.select(.settings)

        let expectedControls: [(String, [String])] = [
            ("audio", [
                "recorder.settings.capture-section",
                "recorder.settings.microphone-picker",
                "recorder.settings.audio-integration-section"
            ]),
            ("recording", [
                "capture-mode-picker",
                "recorder.settings.capture-application-picker",
                "recorder.settings.capture-refresh",
                "teams-auto-recording-toggle",
                "teams-auto-recording-status",
                "teams-mute-sync-status"
            ]),
            ("transcription", [
                "recorder.settings.transcription-profile-status"
            ]),
            ("ai-provider", [RecorderActionID.providerKind]),
            ("storage-shortcuts", [RecorderActionID.chooseOutputFolder])
        ]
        for (section, identifiers) in expectedControls {
            XCTAssertTrue(host.click(
                atAccessibilityFrame: "recorder.settings.navigation.\(section)"
            ))
            XCTAssertTrue(host.revealSettingsControl(
                "recorder.settings.section.\(section)"
            ))
            for identifier in identifiers {
                XCTAssertTrue(
                    host.revealSettingsControl(identifier),
                    "Unreachable \(section) control: \(identifier)"
                )
            }
        }
    }

    func testSettingsRailUsesNativeSelectionForKeyboardNavigation() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }
        host.select(.settings)

        XCTAssertEqual(host.selectedSettingsRailRow, 0)
        XCTAssertTrue(host.pressSettingsRailDownArrow())
        XCTAssertEqual(host.selectedSettingsRailRow, 1)
        XCTAssertTrue(host.containsAccessibilityIdentifier("capture-mode-picker"))
    }

    private func assertVisibleSettingsRecoveryDeepLink(
        for fixture: StartupDisabledFixture
    ) throws {
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        XCTAssertTrue(
            host.visibleContentRect.contains(
                try XCTUnwrap(
                    host.frame(forAccessibilityIdentifier: "recorder.probe.capture-recovery")
                )
            )
        )
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.probe.capture-recovery"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.settings.capture-section"))
    }

    private func makeStartupDisabledFixture(
        systemPermission: CapturePermissionState = .notDetermined,
        microphonePermission: CapturePermissionState = .granted
    ) -> StartupDisabledFixture {
        let suiteName = "RecorderWorkspaceRenderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            defaults: defaults,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false
        )
        model.systemAudioPermission = systemPermission
        model.microphonePermission = microphonePermission
        return .init(
            model: model,
            defaults: defaults
        )
    }

    private func makeFixtureWithOneSession() -> SessionFixture {
        let fixture = makeStartupDisabledFixture(
            systemPermission: .granted,
            microphonePermission: .granted
        )
        let folder = URL(
            fileURLWithPath: "/tmp/recorder-render-session-\(UUID().uuidString)",
            isDirectory: true
        )
        let session = RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 12,
            fileSize: 0,
            metadata: .init(title: "Workspace recording")
        )
        fixture.model.seedLibrarySessionsForTesting([session])
        return .init(model: fixture.model, defaults: fixture.defaults, session: session)
    }

    private func makeLifecycleWorkingFixture() -> LifecycleWorkingFixture {
        let suiteName = "RecorderWorkspaceRenderTests.lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let source = PausedRefreshCaptureSource()
        let recorder = RecordingEngine(captureSource: source)
        let model = AppModel(
            defaults: defaults,
            recorder: recorder,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false
        )
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        model.captureSelection = .init(
            mode: .selectedApplication,
            selectedBundleIdentifier: "com.example.capture"
        )
        return .init(model: model, defaults: defaults, source: source)
    }

    private func makeReadyTeamsFixture() -> StartupDisabledFixture {
        let suiteName =
            "RecorderWorkspaceRenderTests.ready-teams.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let client = RenderTeamsMuteSyncClient()
        let model = AppModel(
            defaults: defaults,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            teamsMuteSyncClient: client,
            teamsIntegrationScheduler: { operation in operation() }
        )
        model.systemAudioPermission = .notDetermined
        model.microphonePermission = .granted
        model.installTeamsMuteSync()
        client.emit(.status(.ready))
        return .init(model: model, defaults: defaults)
    }

    private func waitUntil(
        timeout: TimeInterval,
        message: String = "expected lifecycle state",
        condition: @escaping () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var satisfied = condition()
        while !satisfied, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            satisfied = condition()
        }
        XCTAssertTrue(satisfied, "Timed out waiting for \(message)")
    }

    private func waitUntilAsync(
        timeout: TimeInterval,
        message: String,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        var satisfied = condition()
        while !satisfied, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
            satisfied = condition()
        }
        XCTAssertTrue(satisfied, "Timed out waiting for \(message)")
    }

    private func makeWorkspaceHost(
        model: AppModel,
        size: CGSize,
        systemColorScheme: ColorScheme? = nil
    ) throws -> WorkspaceHost {
        try WorkspaceHost(
            model: model,
            size: size,
            systemColorScheme: systemColorScheme
        )
    }
}

@MainActor
private struct StartupDisabledFixture {
    let model: AppModel
    let defaults: UserDefaults
}

@MainActor
private struct SessionFixture {
    let model: AppModel
    let defaults: UserDefaults
    let session: RecordingSession
}

/// This fixture deliberately mounts the production workspace and opens the
/// production `RecordingsLibraryView` sheet. The local feature fakes only
/// control asynchronous MI work; they do not replace the view under test.
@MainActor
private final class RecordingsMeetingIntelligenceRenderFixture {
    let workspace: URL
    let session: RecordingSession
    let model: AppModel
    let coordinator: MeetingIntelligenceJobCoordinator
    let feature: MeetingIntelligenceFeatureModel
    let transcriptionPreparer: RenderBlockingTranscriptionAudioPreparer
    let generationGate: RenderMeetingIntelligenceGenerationGate
    let generatorEntered: XCTestExpectation
    let generatorFinished: XCTestExpectation
    let published: XCTestExpectation

    init(
        mutationGate: RecordingSessionMutationGate? = nil,
        artifactEditor: (any MeetingIntelligenceArtifactEditing)? = nil
    ) throws {
        let generationGate = RenderMeetingIntelligenceGenerationGate()
        let generatorEntered = XCTestExpectation(description: "recordings MI generation entered")
        let generatorFinished = XCTestExpectation(description: "recordings MI generation finished")
        let published = XCTestExpectation(description: "recordings MI typed publication")
        self.generationGate = generationGate
        self.generatorEntered = generatorEntered
        self.generatorFinished = generatorFinished
        self.published = published
        let transcriptionPreparer = RenderBlockingTranscriptionAudioPreparer()
        self.transcriptionPreparer = transcriptionPreparer
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "recordings-mi-render-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let folder = workspace.appendingPathComponent("recordings-mi-session", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recordingURL = folder.appendingPathComponent("recording.m4a")
        try Data().write(to: recordingURL)
        let transcriptURL = TranscriptDocumentStore.editableURL(in: folder)
        let transcriptData = Data("Production recordings transcript".utf8)
        try transcriptData.write(to: transcriptURL)
        session = .init(
            id: RecordingLibraryURLIdentity.normalized(folder),
            folderURL: folder,
            recordingURL: recordingURL,
            createdAt: .distantPast,
            duration: 12,
            fileSize: 0,
            metadata: .init(title: "Production recordings session")
        )

        let transcript = TranscriptDocumentSnapshot(
            url: transcriptURL,
            data: transcriptData,
            revision: .init(
                sha256: "sha256:" + String(repeating: "c", count: 64),
                byteCount: transcriptData.count
            )
        )
        let generator = RenderMeetingIntelligenceGenerator(
            entered: generatorEntered,
            finished: generatorFinished,
            gate: generationGate
        )
        let providerRepository = RenderMeetingIntelligenceRepository()
        var retainedCoordinator: MeetingIntelligenceJobCoordinator?
        var retainedFeature: MeetingIntelligenceFeatureModel?
        let defaultsName = "RecorderWorkspaceRenderTests.mi.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        let injectedLibraryFeature = mutationGate.map { gate in
            LibraryFeatureModel(
                sessionLoader: { _ in [] },
                sessionReloader: { $0 },
                searchDocumentLoader: { session in
                    RecordingLibrarySearchDocument.load(
                        folderURL: session.folderURL,
                        displayName: session.displayName,
                        createdAt: session.createdAt,
                        metadata: session.metadata
                    )
                },
                recovery: { _ in },
                trashHandler: { _ in true },
                mutationGate: gate
            )
        }
        model = AppModel(
            defaults: defaults,
            providerRepository: providerRepository,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            initialOutputFolder: workspace,
            transcriptionAudioPreparer: transcriptionPreparer,
            libraryFeature: injectedLibraryFeature,
            meetingIntelligenceFeatureFactory: { repository, sourceID, gate in
                let coordinator = MeetingIntelligenceJobCoordinator(
                    providerRepository: repository,
                    expectedPublicationSourceID: sourceID,
                    mutationGate: gate,
                    transcriptReader: RenderMeetingIntelligenceTranscriptReader(snapshot: transcript),
                    availabilityChecker: RenderMeetingIntelligenceAvailability(),
                    generator: generator,
                    publisher: RenderMeetingIntelligencePublisher(published: published),
                    artifactStore: RenderMeetingIntelligenceArtifactStore(),
                    stateStore: RenderMeetingIntelligenceStateStore(),
                    artifactEditor: artifactEditor
                )
                let feature = MeetingIntelligenceFeatureModel(coordinator: coordinator)
                retainedCoordinator = coordinator
                retainedFeature = feature
                return feature
            }
        )
        coordinator = try XCTUnwrap(retainedCoordinator)
        feature = try XCTUnwrap(retainedFeature)
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        model.seedLibrarySessionsForTesting([session])
        // Deliberately detach AppModel's compatibility callback. The durable
        // publisher expectation below still proves publication occurred, while
        // the open production sheet can only update through its observed
        // MeetingIntelligenceFeatureModel snapshot.
        feature.onPublished = { _ in }
    }

    func remove() {
        feature.shutdown()
        transcriptionPreparer.release()
        try? FileManager.default.removeItem(at: workspace)
    }
}

@MainActor
private struct LifecycleWorkingFixture {
    let model: AppModel
    let defaults: UserDefaults
    let source: PausedRefreshCaptureSource
}

@MainActor
private final class WorkspaceNavigationDriver: ObservableObject {
    @Published var navigation = RecorderNavigationState(selection: .record)
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
}

@MainActor
private struct WorkspaceHostRoot: View {
    @ObservedObject var navigationDriver: WorkspaceNavigationDriver
    let model: AppModel
    let reduceTransparencyOverride: Bool?
    let contrast: ColorSchemeContrast
    let systemColorScheme: ColorScheme?

    var body: some View {
        if let systemColorScheme {
            workspace.environment(\.colorScheme, systemColorScheme)
        } else {
            workspace
        }
    }

    private var workspace: some View {
        RecorderWorkspaceContent(
            model: model,
            navigation: Binding(
                get: { navigationDriver.navigation },
                set: { navigationDriver.navigation = $0 }
            ),
            columnVisibility: Binding(
                get: { navigationDriver.columnVisibility },
                set: { navigationDriver.columnVisibility = $0 }
            )
        )
        .environment(
            \.recorderReduceTransparencyOverride,
            reduceTransparencyOverride
        )
        // `colorSchemeContrast` is read-only in the macOS 26 SwiftUI SDK;
        // retain the production environment and inject this deterministic
        // render-test override through the workspace-only test seam.
        .environment(\.recorderColorSchemeContrastOverride, contrast)
    }
}

@MainActor
final class WorkspaceHost {
    private let navigationDriver = WorkspaceNavigationDriver()
    private let hostingView: NSHostingView<WorkspaceHostRoot>
    private let window: NSWindow

    init(
        model: AppModel,
        size: CGSize,
        reduceTransparencyOverride: Bool? = nil,
        contrast: ColorSchemeContrast = .standard,
        systemColorScheme: ColorScheme? = nil
    ) throws {
        hostingView = NSHostingView(
            rootView: WorkspaceHostRoot(
                navigationDriver: navigationDriver,
                model: model,
                reduceTransparencyOverride: reduceTransparencyOverride,
                contrast: contrast,
                systemColorScheme: systemColorScheme
            )
        )
        let frame = NSRect(origin: .zero, size: size)
        hostingView.frame = frame
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        layout()
    }

    func select(_ destination: RecorderDestination) {
        navigationDriver.navigation.select(destination, hasUnsavedChanges: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        layout()
    }

    func containsAccessibilityIdentifier(_ identifier: String) -> Bool {
        view(forAccessibilityIdentifier: identifier) != nil
            || accessibilityElement(forAccessibilityIdentifier: identifier) != nil
            || view(forAccessibilityIdentifier: identifier + ".marker") != nil
    }

    func accessibilityIdentifierCount(_ identifier: String) -> Int {
        renderedRoots.reduce(into: 0) { count, root in
            count += accessibilityIdentifierCount(identifier, in: root)
        }
    }

    func containsAccessibilityLabel(_ label: String) -> Bool {
        view(withAccessibilityLabel: label) != nil
    }

    func containsView(named className: String) -> Bool {
        renderedRoots.flatMap { allViews(startingAt: $0) }.contains {
            String(describing: type(of: $0)).contains(className)
        }
    }

    func isEnabled(_ identifier: String) throws -> Bool {
        if let view = view(forAccessibilityIdentifier: identifier) {
            return view.isAccessibilityEnabled()
        }
        guard let element = accessibilityElement(forAccessibilityIdentifier: identifier) else {
            throw WorkspaceHostError.missingAccessibilityElement(identifier)
        }
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString("accessibilityEnabled")),
              let isEnabled = object.value(forKey: "accessibilityEnabled") as? Bool else {
            throw WorkspaceHostError.missingAccessibilityElement(identifier)
        }
        return isEnabled
    }

    var navigationState: RecorderNavigationState {
        navigationDriver.navigation
    }

    var visibleContentRect: CGRect {
        hostingView.accessibilityFrame()
    }

    var windowContentRect: CGRect {
        let contentRect = window.contentLayoutRect
        return CGRect(
            origin: window.convertPoint(toScreen: contentRect.origin),
            size: contentRect.size
        )
    }

    func frame(forAccessibilityIdentifier identifier: String) -> CGRect? {
        if let element = accessibilityElement(forAccessibilityIdentifier: identifier) {
            return element.accessibilityFrame()
        }
        return view(forAccessibilityIdentifier: identifier)?.accessibilityFrame()
            ?? view(forAccessibilityIdentifier: identifier + ".marker")?
                .accessibilityFrame()
    }

    @discardableResult
    func click(atAccessibilityFrame identifier: String) -> Bool {
        if let section = RecorderSettingsSection(rawValue: String(
            identifier.dropFirst("recorder.settings.navigation.".count)
        )), identifier.hasPrefix("recorder.settings.navigation.") {
            return clickSettingsRailRow(for: section)
        }
        // Prefer the real AppKit control whenever SwiftUI materializes one.
        // Coordinate-only mouse-down dispatch can enter AppKit's synchronous
        // tracking loop before the test has a chance to deliver mouse-up.
        let matchingNativeButtons = renderedRoots
            .flatMap({ allViews(startingAt: $0) })
            .compactMap({ $0 as? NSButton })
            .filter { $0.accessibilityIdentifier() == identifier }
        if let nativeButton = matchingNativeButtons.first(where: {
                guard $0.accessibilityIdentifier() == identifier,
                      !$0.isHidden else { return false }
                let frame = $0.accessibilityFrame()
                return !frame.isEmpty && windowContentRect.intersects(frame)
            }) {
            nativeButton.performClick(nil)
            render()
            return true
        }
        // The Transcript button keeps the pre-existing generic action ID while
        // its passive row marker carries the session-specific ID. Resolve that
        // marker to the intersecting real AppKit control for a stable press.
        if let markerFrame = frame(forAccessibilityIdentifier: identifier),
           let nativeButton = renderedRoots
            .flatMap({ allViews(startingAt: $0) })
            .compactMap({ $0 as? NSButton })
            .first(where: {
                !$0.isHidden
                    && !$0.accessibilityFrame().isEmpty
                    && markerFrame.intersects($0.accessibilityFrame())
            }) {
            nativeButton.performClick(nil)
            render()
            return true
        }
        if performAccessibilityPress(forAccessibilityIdentifier: identifier) {
            render()
            return true
        }
        guard let frame = frame(forAccessibilityIdentifier: identifier) else {
            return false
        }
        let location = window.convertPoint(fromScreen: .init(
            x: frame.midX,
            y: frame.midY
        ))
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return false
        }
        window.sendEvent(down)
        window.sendEvent(up)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        layout()
        return true
    }

    func close() {
        dismissSheets()
        window.orderOut(nil)
        window.contentView = nil
    }

    func dismissSheets() {
        for sheet in window.sheets {
            window.endSheet(sheet)
            sheet.orderOut(nil)
        }
        render()
    }

    func render() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        layout()
    }

    @discardableResult
    func replaceTranscriptEditorText(with text: String) -> Bool {
        guard let editor = transcriptEditorTextView else { return false }
        editor.string = text
        editor.didChangeText()
        render()
        return true
    }

    var transcriptEditorText: String? {
        transcriptEditorTextView?.string
    }

    private var transcriptEditorTextView: NSTextView? {
        if let root = view(
            forAccessibilityIdentifier: "recorder.transcript.editor"
        ), let editor = allViews(startingAt: root)
            .compactMap({ $0 as? NSTextView }).first {
            return editor
        }
        guard let editorFrame = frame(
            forAccessibilityIdentifier: "recorder.transcript.editor"
        ) ?? frame(
            forAccessibilityIdentifier: "recorder.transcript.editor.marker"
        ) else { return nil }
        let editors = renderedRoots
            .flatMap({ allViews(startingAt: $0) })
            .compactMap({ $0 as? NSTextView })
        return editors.first { textView in
                let frame = textView.accessibilityFrame()
                return !frame.isEmpty && editorFrame.intersects(frame)
            }
    }

    func accessibilityValue(for identifier: String) -> Any? {
        view(forAccessibilityIdentifier: identifier)?.accessibilityValue()
    }

    func accessibilityLabel(for identifier: String) -> String? {
        view(forAccessibilityIdentifier: identifier)?.accessibilityLabel()
    }

    func colorSchemeAppearance(for identifier: String) -> NSAppearance.Name? {
        (view(forAccessibilityIdentifier: identifier)
            ?? view(forAccessibilityIdentifier: identifier + ".marker"))?
            .effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua])
    }

    func nativeButtonColorSchemeAppearance(
        for identifier: String
    ) -> NSAppearance.Name? {
        let button = nativeButtons(for: identifier).first
        return button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
    }

    func nativeButtonCount(for identifier: String) -> Int {
        nativeButtons(for: identifier).count
    }

    func nativeButtonFrame(for identifier: String) -> CGRect? {
        nativeButtons(for: identifier).first?.accessibilityFrame()
    }

    func nativeButtonAccessibilityLabel(for identifier: String) -> String? {
        nativeButtons(for: identifier).first?.accessibilityLabel()
    }

    func nonButtonAccessibilityIdentifierCount(_ identifier: String) -> Int {
        renderedRoots
            .flatMap({ allViews(startingAt: $0) })
            .filter {
                !($0 is NSButton) && $0.accessibilityIdentifier() == identifier
            }
            .count
    }

    @discardableResult
    func pressNativeButton(for identifier: String) -> Bool {
        guard let button = nativeButtons(for: identifier).first(where: {
            !$0.isHidden
                && !$0.accessibilityFrame().isEmpty
                && windowContentRect.intersects($0.accessibilityFrame())
        }) else {
            return false
        }
        button.performClick(nil)
        render()
        return true
    }

    func nativeTextFieldColorSchemeAppearance(
        for identifier: String
    ) -> NSAppearance.Name? {
        let textField = renderedRoots
            .flatMap({ allViews(startingAt: $0) })
            .compactMap({ $0 as? NSTextField })
            .first {
                if $0.accessibilityIdentifier() == identifier {
                    return true
                }
                switch identifier {
                case RecorderActionID.metadataTitle:
                    return $0.placeholderString == "Title"
                case RecorderActionID.metadataTags:
                    return $0.placeholderString == "Tags, separated by commas"
                default:
                    return false
                }
            }
        return textField?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
    }

    func revealSettingsControl(_ identifier: String) -> Bool {
        guard let marker = view(forAccessibilityIdentifier: identifier)
            ?? view(forAccessibilityIdentifier: identifier + ".marker") else {
            return false
        }
        marker.scrollToVisible(marker.bounds)
        render()
        return windowContentRect.contains(marker.accessibilityFrame())
    }

    var selectedSettingsRailRow: Int? {
        settingsRailTableView?.selectedRow
    }

    @discardableResult
    func pressSettingsRailDownArrow() -> Bool {
        guard let table = settingsRailTableView else { return false }
        return sendSettingsRailKey(.downArrow, to: table)
    }

    private enum SettingsRailKey {
        case upArrow
        case downArrow

        var characters: String { self == .downArrow ? "\u{F701}" : "\u{F700}" }
        var keyCode: UInt16 { self == .downArrow ? 125 : 126 }
    }

    @discardableResult
    private func sendSettingsRailKey(
        _ key: SettingsRailKey,
        to table: NSTableView
    ) -> Bool {
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
        ) else { return false }
        window.sendEvent(event)
        render()
        return true
    }

    func setColumnVisibility(_ visibility: NavigationSplitViewVisibility) {
        navigationDriver.columnVisibility = visibility
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        layout()
    }

    private func layout() {
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    private var renderedRoots: [NSView] {
        // The transcript detail is an AppKit sheet owned by this host window.
        // Do not search every application window: playback lifecycle tests can
        // leave unrelated `AVPlayerView` windows alive in the same process.
        let windows = [window] + window.sheets + NSApp.windows.filter {
            $0.sheetParent === window
        }
        var seen = Set<ObjectIdentifier>()
        return windows.compactMap(\.contentView).filter {
            seen.insert(ObjectIdentifier($0)).inserted
        }
    }

    private var settingsRailTableView: NSTableView? {
        allViews(startingAt: hostingView).compactMap { $0 as? NSTableView }.first
    }

    private func nativeButtons(for identifier: String) -> [NSButton] {
        renderedRoots
            .flatMap({ allViews(startingAt: $0) })
            .compactMap({ $0 as? NSButton })
            .filter { $0.accessibilityIdentifier() == identifier }
    }

    private func clickSettingsRailRow(for section: RecorderSettingsSection) -> Bool {
        guard let table = settingsRailTableView,
              let row = RecorderSettingsSection.allCases.firstIndex(of: section) else {
            return false
        }
        while table.selectedRow < row {
            guard sendSettingsRailKey(.downArrow, to: table) else { return false }
        }
        while table.selectedRow > row {
            guard sendSettingsRailKey(.upArrow, to: table) else { return false }
        }
        return table.selectedRow == row
    }

    private func view(forAccessibilityIdentifier identifier: String) -> NSView? {
        renderedRoots.lazy.compactMap {
            self.findView(forAccessibilityIdentifier: identifier, in: $0)
        }.first
    }

    private func findView(
        forAccessibilityIdentifier identifier: String,
        in candidate: NSView
    ) -> NSView? {
        if candidate.accessibilityIdentifier() == identifier { return candidate }
        for subview in candidate.subviews {
            if let found = findView(forAccessibilityIdentifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    private func accessibilityIdentifierCount(
        _ identifier: String,
        in candidate: NSView
    ) -> Int {
        let ownCount = candidate.accessibilityIdentifier() == identifier ? 1 : 0
        return ownCount + candidate.subviews.reduce(0) { count, subview in
            count + accessibilityIdentifierCount(identifier, in: subview)
        }
    }

    private func accessibilityElement(
        forAccessibilityIdentifier identifier: String
    ) -> (any NSAccessibilityElementProtocol)? {
        func find(in children: [Any]) -> (any NSAccessibilityElementProtocol)? {
            for child in children {
                if let element = child as? any NSAccessibilityElementProtocol,
                   element.accessibilityIdentifier?() == identifier {
                    return element
                }
                if let found = find(in: accessibilityChildren(of: child)) {
                    return found
                }
            }
            return nil
        }
        for root in renderedRoots {
            if root.accessibilityIdentifier() == identifier {
                return root
            }
            if let found = find(in: root.accessibilityChildren() ?? []) {
                return found
            }
        }
        return nil
    }

    private func performAccessibilityPress(
        forAccessibilityIdentifier identifier: String
    ) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        func find(in children: [Any]) -> NSObject? {
            for child in children {
                if let element = child as? any NSAccessibilityElementProtocol,
                   element.accessibilityIdentifier?() == identifier,
                   let object = child as? NSObject,
                   object.responds(to: selector) {
                    return object
                }
                if let found = find(in: accessibilityChildren(of: child)) {
                    return found
                }
            }
            return nil
        }
        var pressingObject: NSObject?
        for root in renderedRoots {
            if root.accessibilityIdentifier() == identifier,
               root.responds(to: selector) {
                pressingObject = root
                break
            }
            if let found = find(in: root.accessibilityChildren() ?? []) {
                pressingObject = found
                break
            }
        }
        guard let pressingObject else { return false }
        typealias PressFunction = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = pressingObject.method(for: selector)
        let press = unsafeBitCast(implementation, to: PressFunction.self)
        return press(pressingObject, selector)
    }

    private func accessibilityChildren(of element: Any) -> [Any] {
        if let view = element as? NSView {
            return view.accessibilityChildren() ?? []
        }
        if let object = element as? NSObject {
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else {
                return []
            }
            return object.value(forKey: "accessibilityChildren") as? [Any] ?? []
        }
        return []
    }

    private func view(withAccessibilityLabel label: String) -> NSView? {
        renderedRoots.lazy.compactMap {
            self.findView(withAccessibilityLabel: label, in: $0)
        }.first
    }

    private func findView(
        withAccessibilityLabel label: String,
        in candidate: NSView
    ) -> NSView? {
        if candidate.accessibilityLabel() == label { return candidate }
        for subview in candidate.subviews {
            if let found = findView(withAccessibilityLabel: label, in: subview) {
                return found
            }
        }
        return nil
    }

    private func allViews(startingAt view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(startingAt: $0) }
    }

}

private enum WorkspaceHostError: Error {
    case missingAccessibilityElement(String)
}

private final class RenderTeamsMuteSyncClient: TeamsMuteSyncing {
    private var onEvent: ((TeamsMuteSyncEvent) -> Void)?

    func start(onEvent: @escaping (TeamsMuteSyncEvent) -> Void) {
        self.onEvent = onEvent
    }

    func stop() {
        onEvent = nil
    }

    func reconnect() {}

    func requestPairing() {}

    func emit(_ event: TeamsMuteSyncEvent) {
        onEvent?(event)
    }
}

@MainActor
private final class PausedRefreshCaptureSource: CaptureSourceProtocol {
    let screenVideoFormat = ScreenVideoFormat(width: 1_600, height: 900, pixelFormat: 0)
    private(set) var refreshStarted = false
    private var refreshContinuation: CheckedContinuation<Void, Never>?

    func refreshContent() async throws -> [CaptureApplication] {
        refreshStarted = true
        await withCheckedContinuation { refreshContinuation = $0 }
        return []
    }

    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot] { [] }
    func reconnect(selection _: ResolvedCaptureSelection) async throws {}
    func updateVideoTarget(_: TeamsWindowIdentity?) async throws -> CaptureFilterRevision {
        .init(sessionGeneration: 0, revision: 0)
    }
    func start(
        selection _: ResolvedCaptureSelection,
        microphoneUID _: String?,
        onAudio _: @escaping (AudioFrameBlock) -> Void,
        onVideo _: @escaping (ScreenVideoFrame) -> Void,
        onEvent _: @escaping (CaptureEvent) -> Void
    ) async throws {}
    func stop() async {}

    func resumeRefresh() {
        refreshContinuation?.resume()
        refreshContinuation = nil
    }
}

private final class RenderBlockingTranscriptionAudioPreparer: TranscriptionAudioPreparing, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (
        url: URL,
        continuation: CheckedContinuation<PreparedTranscriptionAudio, Never>
    )?
    private var released = false

    func prepare(for session: RecordingSession) async throws -> PreparedTranscriptionAudio {
        try Task.checkCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<PreparedTranscriptionAudio, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume(
                        returning: .init(audioURL: session.recordingURL, cleanupURL: nil)
                    )
                } else {
                    pending = (session.recordingURL, continuation)
                    lock.unlock()
                }
            }
        }, onCancel: {
            release()
        })
    }

    func cleanup(_: PreparedTranscriptionAudio) {}

    func release() {
        lock.lock()
        let pending = self.pending
        self.pending = nil
        released = true
        lock.unlock()
        pending?.continuation.resume(
            returning: .init(audioURL: pending?.url ?? URL(fileURLWithPath: "/tmp/unused.m4a"), cleanupURL: nil)
        )
    }
}

private final class RenderMeetingIntelligenceRepository: OpenAICompatibleProviderManaging, @unchecked Sendable {
    private let value = try! OpenAICompatibleProviderSnapshot.validated(
        profile: .validated(
            baseURLText: "http://127.0.0.1:8080",
            asrModel: "asr",
            llmModel: "llm",
            language: "en",
            prompt: ""
        ),
        apiKey: nil
    )

    func loadProfile() throws -> OpenAICompatibleProviderProfile? { value.profile }
    func setActiveProviderKind(_: AIProviderKind) throws {}
    func save(profile _: OpenAICompatibleProviderProfile, replacementAPIKey _: String?) throws {}
    func snapshot() throws -> OpenAICompatibleProviderSnapshot { value }
    func snapshot(overriding _: OpenAICompatibleProviderProfile) throws -> OpenAICompatibleProviderSnapshot { value }
    func hasAPIKey() throws -> Bool { false }
    func removeAPIKey() throws {}
    func migrateLegacyIfNeeded(settingsURL _: URL) throws -> LegacyProviderMigrationOutcome { .notFound }
}

private struct RenderMeetingIntelligenceAvailability: MeetingIntelligenceAvailabilityChecking {
    func availability(for _: OpenAICompatibleProviderSnapshot) async -> MeetingIntelligenceAvailability { .confirmed }
}

private actor RenderMeetingIntelligenceGenerationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private final class RenderMeetingIntelligenceGenerator: MeetingIntelligenceGenerating, @unchecked Sendable {
    private let entered: XCTestExpectation
    private let finished: XCTestExpectation
    private let gate: RenderMeetingIntelligenceGenerationGate

    init(
        entered: XCTestExpectation,
        finished: XCTestExpectation,
        gate: RenderMeetingIntelligenceGenerationGate
    ) {
        self.entered = entered
        self.finished = finished
        self.gate = gate
    }

    func generate(
        transcript _: TranscriptDocumentSnapshot,
        snapshot _: OpenAICompatibleProviderSnapshot,
        onProgress _: @escaping @Sendable (MeetingIntelligenceProgress) -> Void
    ) async throws -> MeetingIntelligenceGeneratedContent {
        entered.fulfill()
        await gate.wait()
        finished.fulfill()
        return .init(title: "Generated title", summary: "Generated summary")
    }
}

private final class RenderMeetingIntelligenceTranscriptReader: TranscriptDocumentReading, @unchecked Sendable {
    let snapshot: TranscriptDocumentSnapshot

    init(snapshot: TranscriptDocumentSnapshot) {
        self.snapshot = snapshot
    }

    func readCanonical(
        in _: URL,
        allowLegacy _: Bool
    ) throws -> TranscriptDocumentSnapshot {
        snapshot
    }
}

private struct RenderMeetingIntelligencePublisher: MeetingIntelligencePublishing {
    let published: XCTestExpectation

    func publish(
        _ request: MeetingIntelligencePublicationRequest
    ) async throws -> MeetingIntelligencePublicationOutcome {
        published.fulfill()
        return .init(
            artifact: .init(
                schemaVersion: 1,
                summary: "Generated summary",
                suggestedTitle: "Generated title",
                sourceTranscriptSHA256: request.sourceRevision.sha256,
                sourceTranscriptByteCount: request.sourceRevision.byteCount,
                model: request.snapshot.profile.llmModel,
                generatedAt: .distantPast,
                intent: request.intent,
                contentOrigin: .generated,
                editedAt: nil
            ),
            titleOutcome: .applied
        )
    }
}

private final class RenderMeetingIntelligenceArtifactStore: MeetingIntelligenceArtifactStoring, @unchecked Sendable {
    func load(in _: URL) throws -> MeetingIntelligenceArtifact? { nil }
    func stage(_: MeetingIntelligenceArtifact, in _: URL) throws -> URL { URL(fileURLWithPath: "/tmp/render-mi-stage") }
    func promoteStaged(_: URL, in _: URL) throws {}
    func removeStaged(_: URL, in _: URL) throws {}
}

private final class RenderMeetingIntelligenceStateStore: MeetingIntelligenceStateStoring, @unchecked Sendable {
    func load(in _: URL) throws -> MeetingIntelligenceState? { nil }
    func save(_: MeetingIntelligenceState, in _: URL) throws {}
    func remove(in _: URL) throws {}
}

@MainActor
private final class WorkspaceMeetingIntelligenceSaveCapture {
    struct Request: Equatable {
        let session: RecordingSession
        let artifact: MeetingIntelligenceArtifact
        let summary: String
        let suggestedTitle: String
    }

    private(set) var requests: [Request] = []

    func save(
        session: RecordingSession,
        artifact: MeetingIntelligenceArtifact,
        summary: String,
        suggestedTitle: String
    ) async -> MeetingIntelligenceEditSaveOutcome {
        requests.append(.init(
            session: session,
            artifact: artifact,
            summary: summary,
            suggestedTitle: suggestedTitle
        ))
        return .saved(artifact)
    }
}

private actor RenderMeetingIntelligenceEditGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class RenderMeetingIntelligenceEditSpy: MeetingIntelligenceArtifactEditing, @unchecked Sendable {
    struct Request: Equatable {
        let capturedArtifact: MeetingIntelligenceArtifact
        let summary: String
        let suggestedTitle: String
    }

    let entered: XCTestExpectation
    private let gate = RenderMeetingIntelligenceEditGate()
    private let lock = NSLock()
    private var storedRequests: [Request] = []

    init(entered: XCTestExpectation) {
        self.entered = entered
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func save(
        _ request: MeetingIntelligenceArtifactEditRequest
    ) async throws -> MeetingIntelligenceArtifact {
        lock.lock()
        storedRequests.append(.init(
            capturedArtifact: request.capturedArtifact,
            summary: request.proposedSummary,
            suggestedTitle: request.proposedSuggestedTitle
        ))
        lock.unlock()
        entered.fulfill()
        await gate.wait()
        return .init(
            schemaVersion: MeetingIntelligenceArtifact.currentSchemaVersion,
            summary: request.proposedSummary,
            suggestedTitle: request.proposedSuggestedTitle,
            sourceTranscriptSHA256: request.capturedArtifact.sourceTranscriptSHA256,
            sourceTranscriptByteCount: request.capturedArtifact.sourceTranscriptByteCount,
            model: request.capturedArtifact.model,
            generatedAt: request.capturedArtifact.generatedAt,
            intent: request.capturedArtifact.intent,
            contentOrigin: .edited,
            editedAt: request.editedAt
        )
    }

    func release() async {
        await gate.release()
    }
}
