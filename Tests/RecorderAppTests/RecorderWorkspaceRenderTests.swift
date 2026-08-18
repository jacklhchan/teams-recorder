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

}

@MainActor
final class RecorderWorkspaceRenderTests: XCTestCase {
    func testRecoveryCenterRendersMixedGroupsAndRetainedCount() throws {
        let fixture = makeWorkspaceFixture(
            publication: .init(stateText: "Publish failed", pendingCount: 1, waitingCount: 1, needsAttentionCount: 1),
            recoverySnapshot: recoverySnapshot()
        )
        let host = try makeWorkspaceHost(model: fixture.model, size: .init(width: 860, height: 680))
        defer { host.close() }

        host.select(.recovery)
        XCTAssertEqual(host.navigationState.selection, .recovery)
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier(RecorderActionID.recoveryCenterRoot)
        }
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.recoveryCenterRoot))
        XCTAssertTrue(host.containsText("Publishing / Pending"))
        XCTAssertTrue(host.containsText("Waiting for destination"))
        XCTAssertTrue(host.containsText("Needs attention"))
        XCTAssertTrue(host.containsText("3 recordings retained locally"))
        XCTAssertTrue(host.containsText("Publishing local copy"))
        XCTAssertFalse(host.containsText("unsafe-session-name"))
        XCTAssertFalse(host.containsText(fixture.pendingRoot.path))
        XCTAssertFalse(host.containsText("rawFailureCategory"))
    }

    func testRecoveryCenterKeepsHeaderAndActionsVisibleWithManyNeedsAttentionItems() throws {
        let fixture = makeWorkspaceFixture(
            publication: .init(stateText: "Publish failed", pendingCount: 0, waitingCount: 0, needsAttentionCount: 30),
            recoverySnapshot: recoverySnapshot(states: Array(repeating: .needsAttention, count: 30))
        )
        let host = try makeWorkspaceHost(model: fixture.model, size: .init(width: 860, height: 680))
        defer { host.close() }

        host.select(.recovery)
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier(RecorderActionID.recoveryCenterOpenLocal)
        }

        for identifier in [
            "recorder.recovery.title",
            RecorderActionID.recoveryCenterRetainedCount,
            RecorderActionID.recoveryCenterOpenLocal
        ] {
            XCTAssertTrue(
                host.visibleContentRect.contains(
                    try XCTUnwrap(host.frame(forAccessibilityIdentifier: identifier))
                ),
                "\(identifier) must remain reachable without scrolling through recovery items"
            )
        }
    }

    func testRecoveryCenterWaitingItemShowsQueueRetryAndOpenLocalOnly() throws {
        let fixture = makeWorkspaceFixture(
            publication: .init(stateText: "Waiting", pendingCount: 0, waitingCount: 1, needsAttentionCount: 0),
            recoverySnapshot: recoverySnapshot(states: [.waitingForDestination])
        )
        let host = try makeWorkspaceHost(model: fixture.model, size: .init(width: 860, height: 680))
        defer { host.close() }

        host.select(.recovery)
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier(RecorderActionID.recoveryCenterRetry)
        }
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.recoveryCenterRetry))
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.recoveryCenterOpenLocal))
        XCTAssertTrue(host.click(atAccessibilityFrame: RecorderActionID.recoveryCenterRetry))
        XCTAssertEqual(fixture.coordinator.retryNowCalls, 1)
        XCTAssertFalse(host.containsText("Delete"))
        XCTAssertFalse(host.containsText("Cleanup"))
    }

    func testRecoveryCenterLegacyNeedsAttentionHasNoRowAction() throws {
        let fixture = makeWorkspaceFixture(
            publication: .init(stateText: "Publish failed", pendingCount: 0, waitingCount: 0, needsAttentionCount: 1),
            recoverySnapshot: recoverySnapshot(states: [.needsAttention])
        )
        let host = try makeWorkspaceHost(model: fixture.model, size: .init(width: 860, height: 680))
        defer { host.close() }

        host.select(.recovery)
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier(RecorderActionID.recoveryCenterNeedsAttention)
        }
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.recoveryCenterNeedsAttention))
        XCTAssertTrue(host.containsText("This local recording needs attention before it can be published."))
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.recoveryCenterOpenLocal))
        XCTAssertFalse(host.containsAccessibilityIdentifier(RecorderActionID.recoveryCenterRetry))
        XCTAssertFalse(host.containsText("Cleanup"))
    }

    func testRecoveryCenterRestoreAccessUsesExistingDestinationActionOnly() throws {
        let fixture = makeWorkspaceFixture(
            destinationState: .needsFolderAccess,
            publication: .emptyReady,
            recoverySnapshot: .init(presentation: .emptyReady, items: [])
        )
        let host = try makeWorkspaceHost(model: fixture.model, size: .init(width: 860, height: 680))
        defer { host.close() }

        host.select(.recovery)
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier(RecorderActionID.recoveryCenterRestoreAccess)
        }
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.recoveryCenterRestoreAccess))
        XCTAssertFalse(host.containsText("URL"))
        XCTAssertFalse(host.containsText("Path"))
    }

    func testRecordWorkspaceShowsPendingPublicationBannerActions() throws {
        let fixture = makeWorkspaceFixture(
            publication: .init(
                stateText: "Waiting for OneDrive",
                pendingCount: 0,
                waitingCount: 2,
                needsAttentionCount: 0
            )
        )
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        XCTAssertEqual(fixture.model.recordingPublicationPresentation.waitingCount, 2)
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.storage.pending-banner"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.storage.retry"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.storage.open-local"))
        XCTAssertTrue(host.containsText("2 recordings retained locally"))
    }

    func testStorageSettingsExposeDestinationAccessAndNeedsAttention() throws {
        let fixture = makeWorkspaceFixture(
            destinationState: .needsFolderAccess,
            publication: .init(
                stateText: "Publish failed",
                pendingCount: 0,
                waitingCount: 0,
                needsAttentionCount: 1
            )
        )
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }
        host.select(.settings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.storage-shortcuts"))

        XCTAssertEqual(fixture.model.recordingDestinationState, .needsFolderAccess)
        XCTAssertEqual(fixture.model.recordingPublicationPresentation.needsAttentionCount, 1)
        XCTAssertTrue(host.containsText("Needs folder access"))
        XCTAssertTrue(host.containsText("Publishing / Pending: 0"))
        XCTAssertTrue(host.containsText("Waiting: 0"))
        XCTAssertTrue(host.containsText("Needs attention: 1"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.storage.destination-status"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.storage.pending-status"))
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.storage.retry"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.storage.open-local"))
    }

    func testRecordWorkspaceNeedsAttentionOnlyShowsOpenLocalWithoutRetry() throws {
        let fixture = makeWorkspaceFixture(
            publication: .init(
                stateText: "Publish failed",
                pendingCount: 0,
                waitingCount: 0,
                needsAttentionCount: 1
            )
        )
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.storage.pending-banner"))
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.storage.retry"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.storage.open-local"))
    }

    func testStorageSettingsShowsPendingRootMixedCountsAndBothActions() throws {
        let fixture = makeWorkspaceFixture(
            publication: .init(
                stateText: "Publishing",
                pendingCount: 2,
                waitingCount: 3,
                needsAttentionCount: 1
            )
        )
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }
        host.select(.settings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.storage-shortcuts"))

        XCTAssertTrue(host.containsText(fixture.pendingRoot.path))
        XCTAssertTrue(host.containsText("Publishing / Pending: 2"))
        XCTAssertTrue(host.containsText("Waiting: 3"))
        XCTAssertTrue(host.containsText("Needs attention: 1"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.storage.retry"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.storage.open-local"))
    }

    func testReadyWithNoRetainedSessionsDoesNotRenderPendingBanner() throws {
        let fixture = makeWorkspaceFixture(publication: .emptyReady)
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.storage.pending-banner"))
    }

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
            "recorder.row.more.\(rowID)",
            "recorder.row.open.\(rowID)",
            RecorderActionID.openTranscript
        ] {
            XCTAssertEqual(
                host.nativeButtonColorSchemeAppearance(for: identifier),
                expectedNativeAppearance,
                "Compact Recordings action must follow the system appearance: \(identifier)"
            )
        }

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

        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.transcript.\(rowID)"))
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
        let moreID = "recorder.row.more.\(rowID)"
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
            host.nativeButtonCount(for: moreID),
            1,
            "More Actions must be one real NSButton with its per-row identifier",
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.nativeButtonAccessibilityLabel(for: moreID),
            "More Actions for \(fixture.session.displayName)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            host.nativeButtonColorSchemeAppearance(for: moreID),
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
        let moreFrame = try XCTUnwrap(
            host.nativeButtonFrame(for: moreID),
            "Missing real More Actions button frame",
            file: file,
            line: line
        )
        for (name, frame) in [
            ("status", statusFrame),
            ("More Actions", moreFrame)
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

        XCTAssertEqual(
            fixture.model.transcriptionFeature.presentation.transcribingSessionID,
            fixture.session.id,
            file: file,
            line: line
        )
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

    func testDirectionARecordingsRendersCompactGroupedMediaRowsAndSelectsExactlyOne() throws {
        let fixture = try RecordingsMeetingIntelligenceRenderFixture()
        defer { fixture.remove() }
        let secondFolder = fixture.workspace.appendingPathComponent("second", isDirectory: true)
        let second = RecordingSession(
            id: secondFolder, folderURL: secondFolder,
            recordingURL: secondFolder.appendingPathComponent("recording.m4a"),
            createdAt: .now, duration: 20, fileSize: 1,
            metadata: .init(title: "Second recording", mediaKind: .video)
        )
        fixture.model.libraryFeature.seedCanonicalSessionsForTesting(
            [fixture.session, second], workspace: fixture.workspace, fence: .initial
        )
        let host = try makeWorkspaceHost(model: fixture.model, size: .init(width: 860, height: 680))
        defer { host.close() }
        host.select(.recordings)
        let firstID = fixture.session.id.lastPathComponent
        let secondID = second.id.lastPathComponent
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.library.section.today"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.library.filter.all"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.library.filter.favorites"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.library.filter.has-transcript"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.library.filter.needs-attention"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.library.sort"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.row.audio.\(firstID)"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.row.video.\(secondID)"))
        for rowID in [firstID, secondID] {
            XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.row.play.\(rowID)"))
            XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.row.more.\(rowID)"))
        }
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.selected.\(firstID)"))
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.selected.\(secondID)"))
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.transcript.\(firstID)"))
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.transcript.\(secondID)"))
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(firstID)"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.row.selected.\(firstID)"))
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.selected.\(secondID)"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.row.open.\(firstID)"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.row.transcript.\(firstID)"))
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.transcript.\(secondID)"))
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(secondID)"))
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.selected.\(firstID)"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.row.selected.\(secondID)"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.row.open.\(secondID)"))
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.transcript.\(firstID)"))
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.transcript.\(secondID)"))
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

    func testHealthDestinationRendersEmptyThenExistingLastHealthReport() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.health)
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier("recorder.destination.health")
        }
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.destination.health"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.health.empty"))
        XCTAssertTrue(host.containsText("No completed recording health report yet."))
        XCTAssertTrue(host.containsText("Finish a recording to review capture results."))

        fixture.model.lastHealthReport = .init(
            systemSignalSeen: true,
            micSignalSeen: true,
            droppedBuffers: 2
        )
        host.render()

        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier("recorder.health.status")
        }
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.health.status"))
        XCTAssertTrue(host.containsText("Capture needs attention"))
        XCTAssertTrue(host.containsText("System audio captured"))
        XCTAssertTrue(host.containsText("Mic captured"))
        XCTAssertTrue(host.containsAccessibilityIdentifier(
            "recorder.health.counter.dropped-buffers"
        ))
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.health.empty"))
        XCTAssertEqual(host.navigationState.selection, .health)
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
        XCTAssertTrue(host.containsAccessibilityLabel("More Actions for \(fixture.session.displayName)"))
        XCTAssertFalse(host.containsAccessibilityIdentifier(RecorderActionID.openTranscript))
        let rowID = fixture.session.id.lastPathComponent
        for identifier in [
            "recorder.row.play.\(rowID)",
            "recorder.row.more.\(rowID)",
            "recorder.row.open.\(rowID)"
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

    func testTranscribeMenuOpensPerJobSheetAndCancelDoesNotStart() throws {
        let fixture = makeFixtureWithOneSession()
        let model = fixture.model.aiProviderSettingsModel
        model.baseURLText = "https://api.example.com/v1"
        model.asrModel = "asr"
        model.llmModel = "llm"
        model.save()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.recordings)
        let rowID = fixture.session.id.lastPathComponent
        XCTAssertTrue(host.invokeNativeMenuItem(
            forButton: "recorder.row.more.\(rowID)",
            itemIdentifier: "recorder.row.transcribe.\(rowID)"
        ))
        try waitUntil(timeout: 1, message: "transcription sheet to render") {
            host.containsAccessibilityIdentifier(RecorderActionID.transcriptionSheet)
        }
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.transcriptionSheet))
        XCTAssertEqual(
            host.transcriptionPickerValue(for: RecorderActionID.transcriptionLanguage),
            MeetingLanguage.cantonese.rawValue
        )
        XCTAssertEqual(
            host.transcriptionPromptValue(for: RecorderActionID.transcriptionPrompt),
            ""
        )
        XCTAssertTrue(host.selectTranscriptionPickerValue(
            RecorderActionID.transcriptionLanguage,
            value: MeetingLanguage.english.rawValue
        ))
        XCTAssertTrue(host.replaceTextEditor(
            RecorderActionID.transcriptionPrompt,
            with: "discard this draft"
        ))
        XCTAssertTrue(host.click(atAccessibilityFrame: RecorderActionID.transcriptionCancel))
        try waitUntil(timeout: 1, message: "transcription sheet dismissal") {
            !host.containsAccessibilityIdentifier(RecorderActionID.transcriptionSheet)
        }
        XCTAssertFalse(host.containsAccessibilityIdentifier(RecorderActionID.transcriptionSheet))

        XCTAssertTrue(host.invokeNativeMenuItem(
            forButton: "recorder.row.more.\(rowID)",
            itemIdentifier: "recorder.row.transcribe.\(rowID)"
        ))
        try waitUntil(timeout: 1, message: "fresh transcription sheet to render") {
            host.containsAccessibilityIdentifier(RecorderActionID.transcriptionSheet)
        }
        XCTAssertEqual(
            host.transcriptionPickerValue(for: RecorderActionID.transcriptionLanguage),
            MeetingLanguage.cantonese.rawValue
        )
        XCTAssertEqual(
            host.transcriptionPromptValue(for: RecorderActionID.transcriptionPrompt),
            ""
        )
        XCTAssertTrue(host.click(atAccessibilityFrame: RecorderActionID.transcriptionCancel))
        try waitUntil(timeout: 1, message: "fresh transcription sheet dismissal") {
            !host.containsAccessibilityIdentifier(RecorderActionID.transcriptionSheet)
        }
        XCTAssertNil(fixture.model.transcribingSessionID)
    }

    func testTranscriptionSheetMountsPromptEditor() throws {
        let fixture = makeFixtureWithOneSession()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }
        host.select(.recordings)

        fixture.model.requestTranscriptionOptions(sessionID: fixture.session.id)
        try waitUntil(timeout: 1, message: "transcription prompt field") {
            host.containsAccessibilityIdentifier(RecorderActionID.transcriptionSheet)
        }

        let promptFrame = try XCTUnwrap(
            host.frame(forAccessibilityIdentifier: RecorderActionID.transcriptionPrompt),
            "Missing mounted transcription prompt editor"
        )
        XCTAssertFalse(promptFrame.isEmpty)
        XCTAssertTrue(host.windowContentRect.intersects(promptFrame))
        XCTAssertEqual(
            host.transcriptionPromptValue(for: RecorderActionID.transcriptionPrompt),
            ""
        )
        XCTAssertTrue(host.replaceTextEditor(
            RecorderActionID.transcriptionPrompt,
            with: "Names: Ada and Grace"
        ))
        XCTAssertEqual(
            host.transcriptionPromptValue(for: RecorderActionID.transcriptionPrompt),
            "Names: Ada and Grace"
        )
    }

    func testTranscribeImportedCanonicalSessionOpensSharedSheetWithoutStarting() throws {
        let fixture = makeFixtureWithOneSession()
        let settings = fixture.model.aiProviderSettingsModel
        settings.baseURLText = "https://api.example.com/v1"
        settings.asrModel = "asr"
        settings.llmModel = "llm"
        settings.save()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }
        host.select(.recordings)

        fixture.model.requestTranscriptionOptions(
            sessionID: fixture.session.id
        )

        try waitUntil(timeout: 1, message: "import transcription sheet") {
            host.containsAccessibilityIdentifier(
                RecorderActionID.transcriptionSheet
            )
        }
        XCTAssertNil(fixture.model.transcribingSessionID)
        XCTAssertEqual(
            host.transcriptionPickerValue(
                for: RecorderActionID.transcriptionLanguage
            ),
            MeetingLanguage.cantonese.rawValue
        )
        XCTAssertEqual(
            host.transcriptionPickerMarkerAccessibilityValue(
                for: RecorderActionID.transcriptionLanguage
            ),
            MeetingLanguage.cantonese.displayName
        )
        XCTAssertEqual(
            host.transcriptionPromptValue(
                for: RecorderActionID.transcriptionPrompt
            ),
            ""
        )

        XCTAssertTrue(host.click(
            atAccessibilityFrame: RecorderActionID.transcriptionCancel
        ))
        XCTAssertNil(fixture.model.transcriptionRequestDraft)
        try waitUntil(timeout: 1, message: "import sheet dismissal") {
            !host.containsAccessibilityIdentifier(
                RecorderActionID.transcriptionSheet
            )
        }
        XCTAssertNil(fixture.model.transcribingSessionID)
    }

    func testUploadAudioIsDisabledWhileTranscriptionDraftIsPending() throws {
        let fixture = makeFixtureWithOneSession()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }
        host.select(.recordings)
        XCTAssertEqual(
            host.toolbarItemIsEnabled(label: "Upload Audio"),
            true
        )

        fixture.model.requestTranscriptionOptions(
            sessionID: fixture.session.id
        )
        host.render()

        XCTAssertEqual(
            host.toolbarItemIsEnabled(label: "Upload Audio"),
            false
        )
        let draft = try XCTUnwrap(
            fixture.model.transcriptionRequestDraft
        )
        fixture.model.cancelTranscriptionRequest(
            expectedDraftID: draft.id
        )
        host.render()
        XCTAssertEqual(
            host.toolbarItemIsEnabled(label: "Upload Audio"),
            true
        )
    }

    func testTranscriptionSheetSubmitsSelectedLanguageAndPrompt() throws {
        let service = RenderCapturingTranscriptionService()
        let fixture = makeFixtureWithOneSession(
            transcriptionAudioPreparer: RenderImmediateTranscriptionAudioPreparer(),
            transcriptionService: service
        )
        let model = fixture.model.aiProviderSettingsModel
        model.baseURLText = "https://api.example.com/v1"
        model.asrModel = "asr"
        model.llmModel = "llm"
        model.save()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.recordings)
        let rowID = fixture.session.id.lastPathComponent
        XCTAssertTrue(host.invokeNativeMenuItem(
            forButton: "recorder.row.more.\(rowID)",
            itemIdentifier: "recorder.row.transcribe.\(rowID)"
        ))
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.transcriptionSheet))
        XCTAssertEqual(
            host.transcriptionPickerValue(for: RecorderActionID.transcriptionLanguage),
            MeetingLanguage.cantonese.rawValue
        )
        XCTAssertTrue(host.selectTranscriptionPickerValue(
            RecorderActionID.transcriptionLanguage,
            value: MeetingLanguage.english.rawValue
        ))
        XCTAssertTrue(host.replaceTextEditor(
            RecorderActionID.transcriptionPrompt,
            with: "  speaker names  "
        ))
        XCTAssertTrue(host.click(atAccessibilityFrame: RecorderActionID.transcriptionSubmit))
        try waitUntil(timeout: 1, message: "transcription sheet dismissal") {
            !host.containsAccessibilityIdentifier(RecorderActionID.transcriptionSheet)
        }
        XCTAssertFalse(host.containsAccessibilityIdentifier(RecorderActionID.transcriptionSheet))
        try waitUntil(timeout: 1, message: "transcription options capture") {
            service.startedOptions != nil
        }
        XCTAssertEqual(
            service.startedOptions,
            .init(language: .english, prompt: "speaker names")
        )
    }

    func testTranscriptionSheetSubmitDoesNotPressOverlappingUnrelatedButton() throws {
        let service = RenderCapturingTranscriptionService()
        let fixture = makeFixtureWithOneSession(
            transcriptionAudioPreparer: RenderImmediateTranscriptionAudioPreparer(),
            transcriptionService: service
        )
        let settings = fixture.model.aiProviderSettingsModel
        settings.baseURLText = "https://api.example.com/v1"
        settings.asrModel = "asr"
        settings.llmModel = "llm"
        settings.save()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.recordings)
        let rowID = fixture.session.id.lastPathComponent
        XCTAssertTrue(host.invokeNativeMenuItem(
            forButton: "recorder.row.more.\(rowID)",
            itemIdentifier: "recorder.row.transcribe.\(rowID)"
        ))
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.transcriptionSheet))

        let probe = RenderButtonPressProbe()
        let unrelatedButton = NSButton(
            title: "Unrelated",
            target: probe,
            action: #selector(RenderButtonPressProbe.press)
        )
        unrelatedButton.setAccessibilityIdentifier("recorder.test.unrelated")
        XCTAssertTrue(host.addTestOverlayButton(
            unrelatedButton,
            overAccessibilityIdentifier: RecorderActionID.transcriptionSubmit
        ))
        let submitFrame = try XCTUnwrap(
            host.frame(forAccessibilityIdentifier: RecorderActionID.transcriptionSubmit)
        )
        XCTAssertTrue(unrelatedButton.accessibilityFrame().intersects(submitFrame))

        XCTAssertFalse(host.click(
            atAccessibilityFrame: RecorderActionID.transcriptionSubmit
        ))
        XCTAssertEqual(probe.pressCount, 0)
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.transcriptionSheet))

        unrelatedButton.removeFromSuperview()
        XCTAssertTrue(host.click(
            atAccessibilityFrame: RecorderActionID.transcriptionSubmit
        ))
        try waitUntil(timeout: 1, message: "transcription options capture") {
            service.startedOptions != nil
        }
        XCTAssertEqual(
            service.startedOptions,
            .init(language: .cantonese, prompt: "")
        )
    }

    func testRecordingsNativeMenuPreservesExplicitEnablementAndStableActions() throws {
        let fixture = makeFixtureWithOneSession()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.recordings)
        let rowID = fixture.session.id.lastPathComponent
        let items = try XCTUnwrap(
            host.nativeMenuItems(forButton: "recorder.row.more.\(rowID)")
        )

        XCTAssertEqual(items.map(\.title), [
            "Open Folder",
            "Edit Details",
            "Transcribe",
            "Open Transcript",
            "Open ASR Log",
            "Move to Trash"
        ])
        XCTAssertEqual(items.map(\.identifier), [
            "recorder.row.open.\(rowID).menu",
            "recorder.row.edit.\(rowID)",
            "recorder.row.transcribe.\(rowID)",
            "recorder.row.transcript.\(rowID).menu",
            "recorder.row.log.\(rowID)",
            "recorder.row.trash.\(rowID)"
        ])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0.isEnabled) }),
            [
                "Open Folder": true,
                "Edit Details": true,
                "Transcribe": false,
                "Open Transcript": false,
                "Open ASR Log": false,
                "Move to Trash": true
            ]
        )
    }

    func testRecordingsNativeMenuRoutesEnabledTranscriptionAndTranscriptActions() throws {
        let fixture = try RecordingsMeetingIntelligenceRenderFixture()
        defer { fixture.remove() }
        try Data("ASR log".utf8).write(
            to: fixture.session.folderURL.appendingPathComponent(
                TranscriptDocumentStore.logFileName
            )
        )
        fixture.model.aiProviderSettingsModel.reload()
        XCTAssertTrue(fixture.model.aiProviderSettingsModel.hasSavedProfile)
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.recordings)
        let rowID = fixture.session.id.lastPathComponent
        let moreID = "recorder.row.more.\(rowID)"
        let initialItems = try XCTUnwrap(host.nativeMenuItems(forButton: moreID))
        for title in [
            "Open Folder", "Edit Details", "Transcribe",
            "Open Transcript", "Open ASR Log", "Move to Trash"
        ] {
            XCTAssertEqual(
                initialItems.first(where: { $0.title == title })?.isEnabled,
                true,
                "Expected enabled native menu action: \(title)"
            )
        }

        XCTAssertTrue(host.invokeNativeMenuItem(
            forButton: moreID,
            itemIdentifier: "recorder.row.transcribe.\(rowID)"
        ))
        XCTAssertEqual(
            fixture.model.transcriptionFeature.presentation.transcribingSessionID,
            fixture.session.id
        )
        let activeItems = try XCTUnwrap(host.nativeMenuItems(forButton: moreID))
        XCTAssertNil(activeItems.first(where: { $0.title == "Transcribe" }))
        XCTAssertEqual(
            activeItems.first(where: { $0.title == "Cancel Transcription" }),
            .init(
                title: "Cancel Transcription",
                identifier: "recorder.row.transcription-cancel.\(rowID)",
                isEnabled: true
            )
        )
        XCTAssertTrue(host.invokeNativeMenuItem(
            forButton: moreID,
            itemIdentifier: "recorder.row.transcription-cancel.\(rowID)"
        ))
        try waitUntil(timeout: 1, message: "native menu cancellation to settle") {
            fixture.model.transcriptionFeature.presentation.transcribingSessionID == nil
                && fixture.model.transcriptionFeature.presentation
                    .transcriptionStatesBySessionID[fixture.session.id]?.phase == .cancelled
        }

        XCTAssertTrue(host.invokeNativeMenuItem(
            forButton: moreID,
            itemIdentifier: "recorder.row.transcript.\(rowID).menu"
        ))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.transcript.detail.root"))
    }

    func testRecordingsCapturedNativeMenuActionFailsClosedAfterSessionRemoval() throws {
        let fixture = makeFixtureWithOneSession()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.recordings)
        let rowID = fixture.session.id.lastPathComponent
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.row.card.\(rowID)"))
        let action = try XCTUnwrap(host.captureNativeMenuAction(
            forButton: "recorder.row.more.\(rowID)",
            itemIdentifier: "recorder.row.edit.\(rowID)"
        ))

        fixture.model.libraryFeature.seedCanonicalSessionsForTesting(
            [],
            workspace: fixture.model.outputFolder,
            fence: .initial
        )
        host.render()
        XCTAssertFalse(host.containsAccessibilityIdentifier("recorder.row.selected.\(rowID)"))
        XCTAssertTrue(host.invokeCapturedNativeMenuAction(action))
        XCTAssertFalse(host.containsAccessibilityIdentifier(RecorderActionID.metadataTitle))
    }

    func testRecordingsCapturedArtifactActionsFailClosedAfterFilesDisappear() throws {
        let fixture = try RecordingsMeetingIntelligenceRenderFixture()
        defer { fixture.remove() }
        let transcriptURL = TranscriptDocumentStore.editableURL(
            in: fixture.session.folderURL
        )
        let logURL = fixture.session.folderURL.appendingPathComponent(
            TranscriptDocumentStore.logFileName
        )
        try Data("ASR log".utf8).write(to: logURL)
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.recordings)
        let rowID = fixture.session.id.lastPathComponent
        let moreID = "recorder.row.more.\(rowID)"
        let transcriptAction = try XCTUnwrap(host.captureNativeMenuAction(
            forButton: moreID,
            itemIdentifier: "recorder.row.transcript.\(rowID).menu"
        ))
        let logAction = try XCTUnwrap(host.captureNativeMenuAction(
            forButton: moreID,
            itemIdentifier: "recorder.row.log.\(rowID)"
        ))
        XCTAssertTrue(transcriptAction.item.isEnabled)
        XCTAssertTrue(logAction.item.isEnabled)

        try FileManager.default.removeItem(at: transcriptURL)
        try FileManager.default.removeItem(at: logURL)
        let statusBeforeInvocation = fixture.model.statusMessage

        XCTAssertTrue(host.invokeCapturedNativeMenuAction(transcriptAction))
        host.render()
        XCTAssertFalse(host.containsAccessibilityIdentifier(
            "recorder.transcript.detail.root"
        ))
        XCTAssertTrue(host.invokeCapturedNativeMenuAction(logAction))
        XCTAssertEqual(
            fixture.model.statusMessage,
            statusBeforeInvocation,
            "A captured log token must not reach its callback after the log disappears."
        )
    }

    func testRecordingsCapturedTranscribeActionCannotBecomeCancelAfterMenuUpdate() throws {
        let fixture = try RecordingsMeetingIntelligenceRenderFixture()
        defer { fixture.remove() }
        fixture.model.aiProviderSettingsModel.reload()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.recordings)
        let rowID = fixture.session.id.lastPathComponent
        let moreID = "recorder.row.more.\(rowID)"
        let transcribeID = "recorder.row.transcribe.\(rowID)"
        let capturedTranscribe = try XCTUnwrap(host.captureNativeMenuAction(
            forButton: moreID,
            itemIdentifier: transcribeID
        ))

        XCTAssertTrue(host.invokeCapturedNativeMenuAction(capturedTranscribe))
        XCTAssertEqual(
            fixture.model.transcriptionFeature.presentation.transcribingSessionID,
            fixture.session.id
        )
        XCTAssertEqual(
            host.nativeMenuItems(forButton: moreID)?.first(where: {
                $0.title == "Cancel Transcription"
            })?.identifier,
            "recorder.row.transcription-cancel.\(rowID)"
        )

        XCTAssertTrue(host.invokeCapturedNativeMenuAction(capturedTranscribe))
        XCTAssertEqual(capturedTranscribe.item.accessibilityIdentifier(), transcribeID)
        XCTAssertEqual(
            fixture.model.transcriptionFeature.presentation.transcribingSessionID,
            fixture.session.id,
            "A stale Transcribe item must not dispatch the latest Cancel closure."
        )
        XCTAssertNotEqual(
            fixture.model.transcriptionFeature.presentation
                .transcriptionStatesBySessionID[fixture.session.id]?.phase,
            .cancelled
        )
    }

    func testRecordingsCapturedCancelActionCannotBecomeTranscribeAfterMenuUpdate() throws {
        let fixture = try RecordingsMeetingIntelligenceRenderFixture()
        defer { fixture.remove() }
        fixture.model.aiProviderSettingsModel.reload()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.recordings)
        let rowID = fixture.session.id.lastPathComponent
        let moreID = "recorder.row.more.\(rowID)"
        let cancelID = "recorder.row.transcription-cancel.\(rowID)"
        XCTAssertTrue(host.invokeNativeMenuItem(
            forButton: moreID,
            itemIdentifier: "recorder.row.transcribe.\(rowID)"
        ))
        let capturedCancel = try XCTUnwrap(host.captureNativeMenuAction(
            forButton: moreID,
            itemIdentifier: cancelID
        ))

        XCTAssertTrue(host.invokeCapturedNativeMenuAction(capturedCancel))
        try waitUntil(timeout: 1, message: "captured Cancel to settle") {
            fixture.model.transcriptionFeature.presentation.transcribingSessionID == nil
                && fixture.model.transcriptionFeature.presentation
                    .transcriptionStatesBySessionID[fixture.session.id]?.phase == .cancelled
        }
        XCTAssertEqual(
            host.nativeMenuItems(forButton: moreID)?.first(where: {
                $0.title == "Transcribe"
            })?.identifier,
            "recorder.row.transcribe.\(rowID)"
        )

        XCTAssertTrue(host.invokeCapturedNativeMenuAction(capturedCancel))
        XCTAssertEqual(capturedCancel.item.accessibilityIdentifier(), cancelID)
        XCTAssertNil(
            fixture.model.transcriptionFeature.presentation.transcribingSessionID,
            "A stale Cancel item must not dispatch the latest Transcribe closure."
        )
        XCTAssertEqual(
            fixture.model.transcriptionFeature.presentation
                .transcriptionStatesBySessionID[fixture.session.id]?.phase,
            .cancelled
        )
    }

    func testMinimumRecordingsKeepsSessionActionsInsideWindow() throws {
        let fixture = makeFixtureWithOneSession()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.recordings)

        let rowID = fixture.session.id.lastPathComponent
        for identifier in [
            "recorder.row.play.\(rowID)",
            "recorder.row.more.\(rowID)"
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
        XCTAssertTrue(host.containsAccessibilityLabel("More Actions for \(originalName)"))

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
        XCTAssertTrue(host.containsAccessibilityLabel("More Actions for \(renamedName)"))
        XCTAssertFalse(host.containsAccessibilityLabel("Play \(originalName)"))
        XCTAssertFalse(host.containsAccessibilityLabel("More Actions for \(originalName)"))
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
            capturedTranscriptRevision: .init(
                sha256: artifact.sourceTranscriptSHA256,
                byteCount: artifact.sourceTranscriptByteCount
            ),
            summary: "Edited summary",
            suggestedTitle: "Edited suggested title",
            save: { session, artifact, transcriptRevision, summary, suggestedTitle in
                await capture.save(
                    session: session,
                    artifact: artifact,
                    transcriptRevision: transcriptRevision,
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
                    transcriptRevision: .init(
                        sha256: artifact.sourceTranscriptSHA256,
                        byteCount: artifact.sourceTranscriptByteCount
                    ),
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
            capturedTranscriptRevision: .init(
                sha256: artifact.sourceTranscriptSHA256,
                byteCount: artifact.sourceTranscriptByteCount
            ),
            summary: "Should be rejected",
            suggestedTitle: "Should be rejected",
            save: { session, artifact, transcriptRevision, summary, suggestedTitle in
                await capture.save(
                    session: session,
                    artifact: artifact,
                    transcriptRevision: transcriptRevision,
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
            capturedTranscriptRevision: .init(
                sha256: artifact.sourceTranscriptSHA256,
                byteCount: artifact.sourceTranscriptByteCount
            ),
            summary: "Forged summary",
            suggestedTitle: "Forged title",
            save: { session, artifact, transcriptRevision, summary, suggestedTitle in
                await capture.save(
                    session: session,
                    artifact: artifact,
                    transcriptRevision: transcriptRevision,
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
        XCTAssertEqual(
            editor.requests[0].capturedTranscriptRevision,
            .init(
                sha256: capturedArtifact.sourceTranscriptSHA256,
                byteCount: capturedArtifact.sourceTranscriptByteCount
            )
        )
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

    func testPrivacyModeSettingsRendersIdentifiersAndDisabledCopy() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.settings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.transcription"))

        XCTAssertTrue(RecorderActionID.all.contains("recorder.settings.privacy-mode-toggle"))
        XCTAssertTrue(RecorderActionID.all.contains("recorder.settings.privacy-mode-status"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.settings.privacy-mode-toggle"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.settings.privacy-mode-status"))
        XCTAssertEqual(
            host.accessibilityLabel(for: "recorder.settings.privacy-mode-toggle"),
            "Privacy Mode (Local Only)"
        )
        XCTAssertEqual(
            host.accessibilityLabel(for: "recorder.settings.privacy-mode-status"),
            "AI provider actions can use your saved provider settings."
        )
    }

    func testPrivacyModeSettingsToggleChangesPersistsAndProjectsEnabledCopy() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.settings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.transcription"))
        XCTAssertFalse(fixture.model.privacyModeEnabled)

        XCTAssertTrue(host.pressAccessibilityElement("recorder.settings.privacy-mode-toggle"))

        XCTAssertTrue(fixture.model.privacyModeEnabled)
        XCTAssertTrue(fixture.defaults.bool(forKey: PrivacyModePolicy.defaultsKey))
        XCTAssertTrue(PrivacyModePolicy(defaults: fixture.defaults).isEnabled)
        XCTAssertEqual(
            host.accessibilityLabel(for: "recorder.settings.privacy-mode-status"),
            "Recording and local files continue normally. Transcription and meeting intelligence will not contact an AI provider."
        )
    }

    func testLocalRecorderControlSettingsTogglePersistsAndProjectsEnabledCopy() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.settings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.storage-shortcuts"))
        XCTAssertFalse(fixture.model.localRecorderControlEnabled)
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.localRecorderControlToggle))
        XCTAssertTrue(host.pressAccessibilityElement(RecorderActionID.localRecorderControlToggle))

        XCTAssertTrue(fixture.model.localRecorderControlEnabled)
        XCTAssertTrue(fixture.defaults.bool(forKey: LocalRecorderControlPolicy.defaultsKey))
        XCTAssertEqual(
            host.accessibilityLabel(for: RecorderActionID.localRecorderControlStatus),
            "Local command-line control is enabled for this Mac."
        )
    }

    func testLifecycleSafetySettingsDefaultOnAndPersist() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.settings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.storage-shortcuts"))
        XCTAssertTrue(fixture.model.recordingDataLifecyclePolicy.ownerOnlyForNewLocalArtifacts)
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.lifecycleOwnerOnlyToggle))
        XCTAssertTrue(host.pressAccessibilityElement(RecorderActionID.lifecycleOwnerOnlyToggle))

        XCTAssertFalse(fixture.model.recordingDataLifecyclePolicy.ownerOnlyForNewLocalArtifacts)
        XCTAssertFalse(
            RecordingDataLifecyclePolicyStore(defaults: fixture.defaults).load()
                .ownerOnlyForNewLocalArtifacts
        )
        XCTAssertEqual(
            host.accessibilityLabel(for: RecorderActionID.lifecycleOwnerOnlyStatus),
            "New app-owned local artifacts use owner-only permissions when supported."
        )
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.lifecycleRedactionToggle))
        XCTAssertTrue(host.pressAccessibilityElement(RecorderActionID.lifecycleRedactionToggle))
        XCTAssertFalse(fixture.model.recordingDataLifecyclePolicy.redactGeneratedDiagnostics)
        XCTAssertFalse(
            RecordingDataLifecyclePolicyStore(defaults: fixture.defaults).load()
                .redactGeneratedDiagnostics
        )
        XCTAssertEqual(
            host.accessibilityLabel(for: RecorderActionID.lifecycleRedactionStatus),
            "Generated transcription and meeting-intelligence diagnostic content is not persisted; empty compatibility files may remain."
        )
    }

    func testRetentionSettingsStayOffUntilExplicitConfirmation() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.settings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.storage-shortcuts"))
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.retentionToggle))
        XCTAssertFalse(fixture.model.retentionEnableConfirmationRequired)
        XCTAssertTrue(host.pressAccessibilityElement(RecorderActionID.retentionToggle))
        XCTAssertTrue(fixture.model.retentionEnableConfirmationRequired)
        XCTAssertEqual(fixture.model.recordingDataLifecyclePolicy.retention, .disabled)

        fixture.model.confirmRetentionEnabled()
        XCTAssertFalse(fixture.model.retentionEnableConfirmationRequired)
        XCTAssertEqual(
            fixture.model.recordingDataLifecyclePolicy.retention,
            .enabled(
                eligibleClasses: [.transcriptionLog, .transcriptionFailureDiagnostic, .transcriptionBackup],
                olderThanDays: 30
            )
        )
        host.select(.settings)
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.retentionPeriod))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.settings.retention-class.transcriptionLog"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.settings.retention-class.transcriptionFailureDiagnostic"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.settings.retention-class.transcriptionBackup"))
        XCTAssertEqual(
            host.accessibilityLabel(for: RecorderActionID.retentionStatus),
            "Enabled, but this architecture has no safely retained published pending sessions to clean. OneDrive and the recording destination are never scanned."
        )
    }

    func testRetentionAggregateReloadsIntoAppModelWithoutDetails() throws {
        let suiteName = "RecorderWorkspaceRenderTests.retentionAggregate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = RecordingRetentionAggregate(
            eligible: 1,
            skipped: 2,
            deleted: 3,
            errors: 4
        )
        RecordingRetentionAggregateStore(defaults: defaults).save(expected)

        let model = AppModel(
            defaults: defaults,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false
        )

        XCTAssertEqual(model.retentionScanAggregate, expected)
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

    func testMinimumSettingsKeepsAutoRecordingStatusInsideWindow() throws {
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
                forAccessibilityIdentifier: "teams-auto-recording-status"
            ),
            "Missing Teams auto-recording status"
        )
        XCTAssertTrue(
            host.windowContentRect.contains(frame),
            "Teams auto-recording status must remain inside the 860×680 window: \(frame)"
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

    func testMicrophoneRefreshRemainsEnabledWhileRecording() async throws {
        let fixture = makeLifecycleWorkingFixture()
        let recordingFolder = try makeTemporaryRecordingRoot()
        _ = try await fixture.model.recorder.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: recordingFolder
        )
        defer {
            Task { @MainActor in
                _ = await fixture.model.recorder.stop()
                try? FileManager.default.removeItem(at: recordingFolder)
            }
        }

        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }
        host.select(.settings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.audio"))

        XCTAssertFalse(try host.isEnabled("recorder.settings.microphone-picker"))
        XCTAssertTrue(try host.isEnabled("recorder.settings.microphone-refresh"))
    }

    func testMicrophonePickerIsEnabledDuringRecordingWhenLiveSwitchIsSupported() async throws {
        let fixture = makeLiveMicrophoneFixture(supportsLiveSwitch: true)
        let recordingFolder = try await startLiveMicrophoneRecording(fixture)
        defer { stopLiveMicrophoneRecording(fixture, root: recordingFolder) }

        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }
        host.select(.settings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.audio"))

        XCTAssertTrue(RecorderActionID.all.contains(RecorderActionID.microphonePicker))
        XCTAssertTrue(try host.isEnabled(RecorderActionID.microphonePicker))
        XCTAssertTrue(try host.isEnabled("recorder.settings.microphone-refresh"))
    }

    func testMicrophonePickerIsDisabledDuringRecordingWhenLiveSwitchUnsupported() async throws {
        let fixture = makeLiveMicrophoneFixture(supportsLiveSwitch: false)
        let recordingFolder = try await startLiveMicrophoneRecording(fixture)
        defer { stopLiveMicrophoneRecording(fixture, root: recordingFolder) }

        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }
        host.select(.settings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.audio"))

        XCTAssertFalse(try host.isEnabled(RecorderActionID.microphonePicker))
        XCTAssertTrue(try host.isEnabled("recorder.settings.microphone-refresh"))
    }

    func testPendingThenFailedLiveSwitchRestoresOldMicrophoneAndPicker() async throws {
        let fixture = makeLiveMicrophoneFixture(
            supportsLiveSwitch: true,
            pauseSwitch: true
        )
        let recordingFolder = try await startLiveMicrophoneRecording(fixture)
        defer { stopLiveMicrophoneRecording(fixture, root: recordingFolder) }
        fixture.model.selectMicrophone(fixture.replacementMicrophone)
        await waitUntilAsync(timeout: 1, message: "microphone switch to become pending") {
            fixture.source.microphoneSwitchRequests == [fixture.replacementMicrophone.uid]
                && fixture.model.isMicrophoneSwitchPending
        }
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }
        host.select(.settings)
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.settings.navigation.audio"))

        XCTAssertFalse(try host.isEnabled(RecorderActionID.microphonePicker))
        XCTAssertTrue(RecorderActionID.all.contains(RecorderActionID.microphoneSwitchStatus))
        XCTAssertTrue(
            host.containsAccessibilityIdentifier(RecorderActionID.microphoneSwitchStatus)
        )
        XCTAssertEqual(
            host.accessibilityLabel(for: RecorderActionID.microphoneSwitchStatus),
            "Switching microphone…"
        )

        fixture.source.resumeMicrophoneSwitch(
            with: .failed(
                requestedUID: fixture.replacementMicrophone.uid,
                message: "injected"
            )
        )
        await waitUntilAsync(timeout: 1, message: "microphone switch failure") {
            !fixture.model.isMicrophoneSwitchPending
        }
        host.render()

        XCTAssertTrue(try host.isEnabled(RecorderActionID.microphonePicker))
        XCTAssertEqual(fixture.model.selectedMicDevice, fixture.oldMicrophone)
        XCTAssertEqual(fixture.model.statusMessage, "Microphone switch failed")
        XCTAssertEqual(
            host.accessibilityLabel(for: RecorderActionID.microphonePicker),
            fixture.oldMicrophone.displayName
        )
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
                "recorder.settings.microphone-refresh",
                "recorder.settings.audio-integration-section",
                "virtual-mic-privacy-mute-detail"
            ]),
            ("recording", [
                "capture-mode-picker",
                "recorder.settings.capture-application-picker",
                "recorder.settings.capture-refresh",
                "teams-auto-recording-toggle",
                "teams-auto-recording-status"
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
        microphonePermission: CapturePermissionState = .granted,
        transcriptionAudioPreparer: any TranscriptionAudioPreparing =
            TranscriptionAudioPreparer(),
        transcriptionService: (any TranscriptionServicing)? = nil
    ) -> StartupDisabledFixture {
        let suiteName = "RecorderWorkspaceRenderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            defaults: defaults,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            transcriptionAudioPreparer: transcriptionAudioPreparer,
            transcriptionService: transcriptionService
        )
        model.systemAudioPermission = systemPermission
        model.microphonePermission = microphonePermission
        return .init(
            model: model,
            defaults: defaults
        )
    }

    private func makeWorkspaceFixture(
        destinationState: RecordingDestinationState = .ready,
        publication: RecordingPublicationPresentation,
        recoverySnapshot: RecoveryCenterSnapshot = .init(presentation: .emptyReady, items: [])
    ) -> StoragePresentationFixture {
        let suiteName = "RecorderWorkspaceRenderTests.storage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let destination = URL(
            fileURLWithPath: "/tmp/recorder-storage-render-\(UUID().uuidString)",
            isDirectory: true
        )
        let destinationStore = RenderDestinationStore(
            url: destination,
            state: destinationState
        )
        let coordinator = RenderPublicationCoordinator(presentation: publication, recoveryCenterSnapshot: recoverySnapshot)
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "recorder-storage-render-paths-\(UUID().uuidString)",
            isDirectory: true
        )
        let appPaths = AppPaths(
            homeDirectory: testRoot,
            applicationSupportRoot: testRoot
        )
        let model = AppModel(
            defaults: defaults,
            appPaths: appPaths,
            recordingDestinationStore: destinationStore,
            recordingPublicationCoordinator: coordinator,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false
        )
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        return .init(
            model: model,
            defaults: defaults,
            pendingRoot: appPaths.pendingRecordingsDirectory,
            coordinator: coordinator
        )
    }

    private func recoverySnapshot(
        states: [RecoveryCenterItemState] = [.publishingOrPending, .waitingForDestination, .needsAttention]
    ) -> RecoveryCenterSnapshot {
        let items = states.enumerated().map { index, state in
            RecoveryCenterItem(
                id: UUID(), source: index == 1 ? .teamsAutomatic : .manual,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                state: state,
                safeStatusText: state == .needsAttention
                    ? "This local recording needs attention before it can be published."
                    : state == .waitingForDestination ? "Destination access is needed" : "Publishing local copy",
                canRetry: state == .waitingForDestination
            )
        }
        return .init(
            presentation: .init(stateText: "Publish failed", pendingCount: states.filter { $0 == .publishingOrPending }.count, waitingCount: states.filter { $0 == .waitingForDestination }.count, needsAttentionCount: states.filter { $0 == .needsAttention }.count),
            items: items
        )
    }

    private func makeFixtureWithOneSession(
        transcriptionAudioPreparer: any TranscriptionAudioPreparing =
            TranscriptionAudioPreparer(),
        transcriptionService: (any TranscriptionServicing)? = nil
    ) -> SessionFixture {
        let fixture = makeStartupDisabledFixture(
            systemPermission: .granted,
            microphonePermission: .granted,
            transcriptionAudioPreparer: transcriptionAudioPreparer,
            transcriptionService: transcriptionService
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
        let recorder = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in RenderTestWriter() }
        )
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

    private func makeLiveMicrophoneFixture(
        supportsLiveSwitch: Bool,
        pauseSwitch: Bool = false
    ) -> LiveMicrophoneFixture {
        let suiteName = "RecorderWorkspaceRenderTests.live-microphone.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let oldMicrophone = AudioDevice(
            id: 1,
            uid: "mic-a",
            name: "Old microphone",
            manufacturer: "Tests",
            channelCount: 1
        )
        let replacementMicrophone = AudioDevice(
            id: 2,
            uid: "mic-b",
            name: "Replacement microphone",
            manufacturer: "Tests",
            channelCount: 2
        )
        defaults.set(
            oldMicrophone.uid,
            forKey: CaptureSelectionPersistence.microphoneUIDKey
        )
        let source = PausedRefreshCaptureSource()
        source.supportsLiveMicrophoneSwitch = supportsLiveSwitch
        source.pauseMicrophoneSwitch = pauseSwitch
        let recorder = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in RenderTestWriter() }
        )
        let model = AppModel(
            defaults: defaults,
            recorder: recorder,
            inputDevices: { [oldMicrophone, replacementMicrophone] },
            defaultInputDeviceID: { oldMicrophone.id },
            performStartupWork: false
        )
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        return .init(
            model: model,
            source: source,
            oldMicrophone: oldMicrophone,
            replacementMicrophone: replacementMicrophone
        )
    }

    private func startLiveMicrophoneRecording(
        _ fixture: LiveMicrophoneFixture
    ) async throws -> URL {
        let recordingRoot = try makeTemporaryRecordingRoot()
        _ = try await fixture.model.recorder.start(
            selection: .allSystemAudio,
            microphoneUID: fixture.oldMicrophone.uid,
            baseFolder: recordingRoot
        )
        return recordingRoot
    }

    private func stopLiveMicrophoneRecording(
        _ fixture: LiveMicrophoneFixture,
        root: URL
    ) {
        Task { @MainActor in
            _ = await fixture.model.recorder.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeTemporaryRecordingRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-mic-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeReadyTeamsFixture() -> StartupDisabledFixture {
        let suiteName =
            "RecorderWorkspaceRenderTests.ready-teams.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            defaults: defaults,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false
        )
        model.systemAudioPermission = .notDetermined
        model.microphonePermission = .granted
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

@MainActor
private struct StoragePresentationFixture {
    let model: AppModel
    let defaults: UserDefaults
    let pendingRoot: URL
    let coordinator: RenderPublicationCoordinator
}

private extension RecordingPublicationPresentation {
    static let emptyReady = RecordingPublicationPresentation(
        stateText: "Up to date",
        pendingCount: 0,
        waitingCount: 0,
        needsAttentionCount: 0
    )
}

@MainActor
private final class RenderPublicationCoordinator: RecordingPublicationCoordinating {
    var presentation: RecordingPublicationPresentation
    var onPresentationChange: ((RecordingPublicationPresentation) -> Void)?
    var recoveryCenterSnapshot: RecoveryCenterSnapshot
    var onRecoveryCenterSnapshotChange: ((RecoveryCenterSnapshot) -> Void)?
    var onCompleted: ((RecordingPublicationCompleted) -> Void)?

    private(set) var retryNowCalls = 0

    init(presentation: RecordingPublicationPresentation, recoveryCenterSnapshot: RecoveryCenterSnapshot) {
        self.presentation = presentation
        self.recoveryCenterSnapshot = recoveryCenterSnapshot
    }

    func enqueue(_: RecordingPublicationRequest) {}
    func resume() {}
    func retryNow() { retryNowCalls += 1 }
    func shutdown() {}
}

private final class RenderDestinationStore: RecordingDestinationStoring {
    private(set) var currentIdentity: RecordingDestinationIdentity? = .init(id: UUID())
    private var url: URL
    private var state: RecordingDestinationState

    init(url: URL, state: RecordingDestinationState) {
        self.url = url
        self.state = state
    }

    func restore(defaultURL _: URL) -> RecordingDestinationSelection {
        .init(identity: currentIdentity, url: url, state: state)
    }

    func save(_ url: URL) throws {
        self.url = url
        state = .ready
    }

    func access(identity _: RecordingDestinationIdentity) throws -> RecordingDestinationAccess {
        .init(url: url, close: {})
    }

    func prune(keeping _: Set<RecordingDestinationIdentity>) {}
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
            meetingIntelligenceFeatureFactory: { repository, sourceID, gate, admission, _ in
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
                    artifactEditor: artifactEditor,
                    thirdPartyProcessingAdmission: admission
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
private struct LiveMicrophoneFixture {
    let model: AppModel
    let source: PausedRefreshCaptureSource
    let oldMicrophone: AudioDevice
    let replacementMicrophone: AudioDevice
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

fileprivate struct NativeMenuItemSnapshot: Equatable {
    let title: String
    let identifier: String
    let isEnabled: Bool
}

fileprivate struct CapturedNativeMenuAction {
    let item: NSMenuItem
    let target: AnyObject
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
        var navigation = navigationDriver.navigation
        navigation.select(destination, hasUnsavedChanges: false)
        navigationDriver.navigation = navigation
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

    func containsText(_ text: String) -> Bool {
        renderedRoots.flatMap { allViews(startingAt: $0) }.contains { view in
            if let textField = view as? NSTextField {
                return textField.stringValue.contains(text) && !textField.isHidden
            }
            return view.accessibilityLabel()?.contains(text) == true && !view.isHidden
        }
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
        accessibilityTarget(forAccessibilityIdentifier: identifier)?
            .element.accessibilityFrame()
    }

    @discardableResult
    func click(atAccessibilityFrame identifier: String) -> Bool {
        if let section = RecorderSettingsSection(rawValue: String(
            identifier.dropFirst("recorder.settings.navigation.".count)
        )), identifier.hasPrefix("recorder.settings.navigation.") {
            return clickSettingsRailRow(for: section)
        }
        guard let target = accessibilityTarget(
            forAccessibilityIdentifier: identifier
        ), let targetRoot = target.window.contentView else {
            return false
        }
        // Prefer the real AppKit control whenever SwiftUI materializes one.
        // Coordinate-only mouse-down dispatch can enter AppKit's synchronous
        // tracking loop before the test has a chance to deliver mouse-up.
        let matchingNativeButtons = allViews(startingAt: targetRoot)
            .compactMap({ $0 as? NSButton })
            .filter { $0.accessibilityIdentifier() == identifier }
        if let nativeButton = matchingNativeButtons.first(where: {
                guard $0.accessibilityIdentifier() == identifier,
                      !$0.isHidden else { return false }
                let frame = $0.accessibilityFrame()
                return !frame.isEmpty && target.window.frame.intersects(frame)
            }) {
            nativeButton.performClick(nil)
            render()
            return true
        }
        // Collect all exact-ID AX candidates in the target sheet and let the
        // first candidate that actually performs a press win. This keeps a
        // passive marker from shadowing a real actionable AX element.
        for element in accessibilityElements(
            forAccessibilityIdentifier: identifier,
            in: target.window
        ) {
            if performAccessibilityPress(on: element) {
                render()
                return true
            }
        }
        if performAccessibilityPress(on: target.element) {
            render()
            return true
        }
        // The Transcript button keeps the pre-existing generic action ID while
        // its passive row marker carries the session-specific ID. Bind that
        // marker to the known production action ID; never choose an arbitrary
        // intersecting native button.
        let markerFrame = target.element.accessibilityFrame()
        let isTranscriptRowMarker =
            identifier.hasPrefix("recorder.row.transcript.")
                && target.element.accessibilityIdentifier?() == "\(identifier).marker"
        if isTranscriptRowMarker,
           let nativeButton = allViews(startingAt: targetRoot)
            .compactMap({ $0 as? NSButton })
            .first(where: {
                $0.accessibilityIdentifier() == RecorderActionID.openTranscript
                    &&
                !$0.isHidden
                    && !$0.accessibilityFrame().isEmpty
                    && markerFrame.intersects($0.accessibilityFrame())
            }) {
            nativeButton.performClick(nil)
            render()
            return true
        }
        let screenPoint = NSPoint(x: markerFrame.midX, y: markerFrame.midY)
        let location = target.window.convertPoint(fromScreen: screenPoint)
        let hitView = target.window.contentView?.hitTest(location)
        guard let hitView,
              !sequence(first: hitView, next: { $0.superview })
                .contains(where: { $0 is NSControl }) else {
            return false
        }
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: target.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: target.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return false
        }
        target.window.sendEvent(down)
        target.window.sendEvent(up)
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
    func selectTranscriptionPickerValue(
        _ identifier: String,
        value: String
    ) -> Bool {
        guard let markerFrame = frame(forAccessibilityIdentifier: identifier),
              let picker = renderedRoots
                  .flatMap({ allViews(startingAt: $0) })
                  .compactMap({ $0 as? NSPopUpButton })
                  .first(where: {
                      !$0.isHidden && markerFrame.intersects($0.accessibilityFrame())
                  }),
              let language = MeetingLanguage(rawValue: value),
              let item = picker.itemArray.first(where: {
                  $0.title == language.displayName
              }), let action = item.action else {
            return false
        }
        let didSend = NSApp.sendAction(action, to: item.target, from: item)
        render()
        return didSend
    }

    func transcriptionPickerValue(for identifier: String) -> String? {
        guard let markerFrame = frame(forAccessibilityIdentifier: identifier),
              let picker = renderedRoots
                  .flatMap({ allViews(startingAt: $0) })
                  .compactMap({ $0 as? NSPopUpButton })
                  .first(where: {
                      !$0.isHidden && markerFrame.intersects($0.accessibilityFrame())
                  }),
              let title = picker.selectedItem?.title else {
            return nil
        }
        return MeetingLanguage.allCases.first {
            $0.displayName == title
        }?.rawValue
    }

    func transcriptionPickerMarkerAccessibilityValue(
        for identifier: String
    ) -> String? {
        return renderedRoots
            .flatMap({ allViews(startingAt: $0) })
            .first(where: {
                $0.accessibilityIdentifier() == identifier
                    && !($0 is NSControl)
                    && $0.accessibilityValue() is String
            })?
            .accessibilityValue() as? String
    }

    func transcriptionPromptValue(for identifier: String) -> String? {
        guard let markerFrame = frame(forAccessibilityIdentifier: identifier),
              let editor = renderedRoots
                  .flatMap({ allViews(startingAt: $0) })
                  .compactMap({ $0 as? NSTextView })
                  .first(where: {
                      !$0.isHidden && markerFrame.intersects($0.accessibilityFrame())
                  }) else {
            return nil
        }
        return editor.string
    }

    @discardableResult
    func addTestOverlayButton(
        _ button: NSButton,
        overAccessibilityIdentifier identifier: String
    ) -> Bool {
        guard let target = accessibilityTarget(
            forAccessibilityIdentifier: identifier
        ), let contentView = target.window.contentView else {
            return false
        }
        let markerFrame = target.element.accessibilityFrame()
        let windowOrigin = target.window.convertPoint(fromScreen: markerFrame.origin)
        let origin = contentView.convert(windowOrigin, from: nil)
        button.frame = .init(origin: origin, size: markerFrame.size)
        button.isHidden = false
        contentView.addSubview(button, positioned: .above, relativeTo: nil)
        layout()
        let accessibilityDelta = CGPoint(
            x: markerFrame.midX - button.accessibilityFrame().midX,
            y: markerFrame.midY - button.accessibilityFrame().midY
        )
        button.setFrameOrigin(
            .init(
                x: button.frame.origin.x + accessibilityDelta.x,
                y: button.frame.origin.y - accessibilityDelta.y
            )
        )
        layout()
        return true
    }

    @discardableResult
    func replaceTextEditor(_ identifier: String, with text: String) -> Bool {
        guard let markerFrame = frame(forAccessibilityIdentifier: identifier),
              let editor = renderedRoots
                  .flatMap({ allViews(startingAt: $0) })
                  .compactMap({ $0 as? NSTextView })
                  .first(where: {
                      !$0.isHidden && markerFrame.intersects($0.accessibilityFrame())
                  }) else {
            return false
        }
        editor.string = text
        editor.didChangeText()
        render()
        return true
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
        if let label = view(forAccessibilityIdentifier: identifier)?
            .accessibilityLabel() {
            return label
        }
        guard let element = accessibilityElement(
            forAccessibilityIdentifier: identifier
        ) as? NSObject,
        element.responds(to: NSSelectorFromString("accessibilityLabel")) else {
            return nil
        }
        return element.value(forKey: "accessibilityLabel") as? String
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

    func toolbarItemIsEnabled(label: String) -> Bool? {
        window.toolbar?.validateVisibleItems()
        return window.toolbar?.items.lazy.compactMap { item in
            if let group = item as? NSToolbarItemGroup {
                return group.subitems.first(where: { $0.label == label })?
                    .isEnabled
            }
            return item.label == label ? item.isEnabled : nil
        }.first
    }

    fileprivate func nativeMenuItems(
        forButton identifier: String
    ) -> [NativeMenuItemSnapshot]? {
        guard let menu = nativeButtons(for: identifier).first?.menu else {
            return nil
        }
        menu.update()
        return menu.items.compactMap { item in
            guard !item.isSeparatorItem else { return nil }
            return NativeMenuItemSnapshot(
                title: item.title,
                identifier: item.accessibilityIdentifier(),
                isEnabled: item.isEnabled
            )
        }
    }

    fileprivate func captureNativeMenuAction(
        forButton buttonIdentifier: String,
        itemIdentifier: String
    ) -> CapturedNativeMenuAction? {
        guard let menu = nativeButtons(for: buttonIdentifier).first?.menu else {
            return nil
        }
        menu.update()
        guard let item = menu.items.first(where: {
            $0.accessibilityIdentifier() == itemIdentifier
        }), let target = item.target else {
            return nil
        }
        return CapturedNativeMenuAction(item: item, target: target)
    }

    @discardableResult
    func invokeNativeMenuItem(
        forButton buttonIdentifier: String,
        itemIdentifier: String
    ) -> Bool {
        guard let action = captureNativeMenuAction(
            forButton: buttonIdentifier,
            itemIdentifier: itemIdentifier
        ), action.item.isEnabled else {
            return false
        }
        return invokeCapturedNativeMenuAction(action)
    }

    @discardableResult
    fileprivate func invokeCapturedNativeMenuAction(
        _ action: CapturedNativeMenuAction
    ) -> Bool {
        guard let selector = action.item.action else { return false }
        let didSend = NSApp.sendAction(
            selector,
            to: action.target,
            from: action.item
        )
        render()
        return didSend
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

    @discardableResult
    func pressAccessibilityElement(_ identifier: String) -> Bool {
        let didPress: Bool
        if let marker = view(forAccessibilityIdentifier: identifier)
            as? RecorderSettingsAccessibilityMarkerView {
            didPress = marker.accessibilityPerformPress()
        } else {
            didPress = performAccessibilityPress(
                forAccessibilityIdentifier: identifier
            )
        }
        render()
        return didPress
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

    private var renderedWindows: [NSWindow] {
        // The transcript detail is an AppKit sheet owned by this host window.
        // Do not search every application window: playback lifecycle tests can
        // leave unrelated `AVPlayerView` windows alive in the same process.
        let windows = [window] + window.sheets + NSApp.windows.filter {
            $0.sheetParent === window
        }
        var seen = Set<ObjectIdentifier>()
        return windows.filter {
            seen.insert(ObjectIdentifier($0)).inserted
        }
    }

    private var renderedRoots: [NSView] {
        var seen = Set<ObjectIdentifier>()
        return renderedWindows.compactMap(\.contentView).filter {
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
        accessibilityTarget(forAccessibilityIdentifier: identifier)?.element
    }

    private func performAccessibilityPress(
        forAccessibilityIdentifier identifier: String
    ) -> Bool {
        guard let element = accessibilityTarget(
            forAccessibilityIdentifier: identifier
        )?.element else {
            return false
        }
        return performAccessibilityPress(on: element)
    }

    private func performAccessibilityPress(
        on element: any NSAccessibilityElementProtocol
    ) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard let pressingObject = element as? NSObject,
              pressingObject.responds(to: selector) else { return false }
        typealias PressFunction = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = pressingObject.method(for: selector)
        let press = unsafeBitCast(implementation, to: PressFunction.self)
        return press(pressingObject, selector)
    }

    private func accessibilityElements(
        forAccessibilityIdentifier identifier: String,
        in candidateWindow: NSWindow
    ) -> [any NSAccessibilityElementProtocol] {
        guard let root = candidateWindow.contentView else { return [] }

        func collect(
            in children: [Any],
            into matches: inout [any NSAccessibilityElementProtocol]
        ) {
            for child in children {
                if let element = child as? any NSAccessibilityElementProtocol,
                   element.accessibilityIdentifier?() == identifier {
                    matches.append(element)
                }
                collect(
                    in: accessibilityChildren(of: child),
                    into: &matches
                )
            }
        }

        var matches: [any NSAccessibilityElementProtocol] = []
        if root.accessibilityIdentifier() == identifier {
            matches.append(root)
        }
        collect(
            in: root.accessibilityChildren() ?? [],
            into: &matches
        )
        return matches
    }

    private func accessibilityTarget(
        forAccessibilityIdentifier identifier: String
    ) -> (
        window: NSWindow,
        element: any NSAccessibilityElementProtocol
    )? {
        func find(
            in children: [Any]
        ) -> (any NSAccessibilityElementProtocol)? {
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

        for candidateWindow in renderedWindows.reversed() {
            guard let root = candidateWindow.contentView else { continue }
            if root.accessibilityIdentifier() == identifier {
                return (candidateWindow, root)
            }
            if let element = find(in: root.accessibilityChildren() ?? []) {
                return (candidateWindow, element)
            }
            if let view = findView(
                forAccessibilityIdentifier: identifier,
                in: root
            ) ?? findView(
                forAccessibilityIdentifier: identifier + ".marker",
                in: root
            ) {
                return (candidateWindow, view)
            }
        }
        return nil
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

@MainActor
private final class PausedRefreshCaptureSource: CaptureSourceProtocol {
    let screenVideoFormat = ScreenVideoFormat(width: 1_600, height: 900, pixelFormat: 0)
    nonisolated(unsafe) var supportsLiveMicrophoneSwitch = false
    var pauseMicrophoneSwitch = false
    private(set) var refreshStarted = false
    private(set) var microphoneSwitchRequests: [String?] = []
    private var refreshContinuation: CheckedContinuation<Void, Never>?
    private var microphoneSwitchContinuation:
        CheckedContinuation<MicrophoneSwitchOutcome, Never>?

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
    func switchMicrophone(
        to microphoneUID: String?,
        lifecycle _: MicrophoneSwitchLifecycleToken
    ) async -> MicrophoneSwitchOutcome {
        microphoneSwitchRequests.append(microphoneUID)
        if pauseMicrophoneSwitch {
            return await withCheckedContinuation {
                microphoneSwitchContinuation = $0
            }
        }
        return .failed(requestedUID: microphoneUID, message: "injected")
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

    func resumeMicrophoneSwitch(with outcome: MicrophoneSwitchOutcome) {
        microphoneSwitchContinuation?.resume(returning: outcome)
        microphoneSwitchContinuation = nil
    }
}

private final class RenderTestWriter: MixedAudioWriting {
    func write(_: MixedAudioBlock) throws {}
    func close() throws {}
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
        let transcriptRevision: TranscriptDocumentRevision
        let summary: String
        let suggestedTitle: String
    }

    private(set) var requests: [Request] = []

    func save(
        session: RecordingSession,
        artifact: MeetingIntelligenceArtifact,
        transcriptRevision: TranscriptDocumentRevision,
        summary: String,
        suggestedTitle: String
    ) async -> MeetingIntelligenceEditSaveOutcome {
        requests.append(.init(
            session: session,
            artifact: artifact,
            transcriptRevision: transcriptRevision,
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
        let capturedTranscriptRevision: TranscriptDocumentRevision
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
        lock.withLock { storedRequests }
    }

    func save(
        _ request: MeetingIntelligenceArtifactEditRequest
    ) async throws -> MeetingIntelligenceArtifact {
        lock.withLock {
            storedRequests.append(.init(
                capturedArtifact: request.capturedArtifact,
                capturedTranscriptRevision: request.capturedTranscriptRevision,
                summary: request.proposedSummary,
                suggestedTitle: request.proposedSuggestedTitle
            ))
        }
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

private struct RenderImmediateTranscriptionAudioPreparer: TranscriptionAudioPreparing {
    func prepare(for session: RecordingSession) async throws -> PreparedTranscriptionAudio {
        .init(audioURL: session.recordingURL, cleanupURL: nil)
    }

    func cleanup(_: PreparedTranscriptionAudio) {}
}

private enum RenderTranscriptionError: Error {
    case stopAfterCapture
}

private final class RenderButtonPressProbe: NSObject {
    private(set) var pressCount = 0

    @objc func press() {
        pressCount += 1
    }
}

private final class RenderCapturingTranscriptionService: TranscriptionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var request: TranscriptionServiceRequest?

    var startedOptions: TranscriptionRequestOptions? {
        lock.withLock {
            guard let profile = request?.snapshot.profile,
                  let language = MeetingLanguage(rawValue: profile.language) else {
                return nil
            }
            return .init(language: language, prompt: profile.prompt)
        }
    }

    func transcribe(
        _ request: TranscriptionServiceRequest,
        onProgress _: @escaping @Sendable (TranscriptionServiceProgress) -> Void
    ) async throws -> TranscriptionServiceResult {
        lock.withLock { self.request = request }
        throw RenderTranscriptionError.stopAfterCapture
    }
}
