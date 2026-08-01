import Foundation
import XCTest
@testable import RecorderApp

/// Task 5 RED contract. `PRBFeatureBridge.Routes` is a narrow internal seam:
/// it registers real producer callbacks and issues real domain commands. It
/// must not introduce an alternate event or identity vocabulary for tests.
@MainActor
final class PRBFeatureBridgeTests: XCTestCase {
    func testStartIsIdempotentAndRegistersNineRealProducerCallbacks() {
        let (bridge, route) = makeSUT()
        bridge.start()
        bridge.start()
        route.emitTranscript(publication("one"))
        XCTAssertEqual(route.registrationCount, 9)
        XCTAssertEqual(route.acceptedTranscriptAttemptIDs.count, 1)
    }

    func testTranscriptPublicationCommitsLibraryBeforeOneMIAdmission() {
        let (bridge, route) = makeSUT(); bridge.start()
        let event = publication("asr")
        route.emitTranscript(event)
        XCTAssertEqual(route.acceptedTranscriptAttemptIDs, [event.identity.attemptID])
        XCTAssertTrue(route.miTranscriptAttemptIDs.isEmpty)
        route.emitLibraryCommit(committed(event))
        XCTAssertEqual(route.miTranscriptAttemptIDs, [event.identity.attemptID])
    }

    func testOrphanOrForgedLibraryCommitCannotTriggerMI() {
        let (bridge, route) = makeSUT(); bridge.start()
        let orphan = publication("orphan")
        route.emitLibraryCommit(committed(orphan))
        let admitted = publication("admitted")
        route.emitTranscript(admitted)
        var forged = committed(admitted)
        forged = .init(identity: forged.identity, publication: publication("different"), canonicalSession: session)
        route.emitLibraryCommit(forged)
        XCTAssertTrue(route.miTranscriptAttemptIDs.isEmpty)
        route.emitLibraryCommit(committed(admitted))
        XCTAssertEqual(route.miTranscriptAttemptIDs, [admitted.identity.attemptID])
    }

    func testWorkspaceChangeClearsPendingASRToLibraryCausality() {
        let (bridge, route) = makeSUT(); bridge.start()
        let event = publication("pending")
        route.emitTranscript(event)
        bridge.workspaceDidChange(.init(workspace: .init(folder: workspace, fence: currentFence)))
        route.emitLibraryCommit(committed(event))
        XCTAssertTrue(route.miTranscriptAttemptIDs.isEmpty)
    }

    func testDuplicateForgedStaleAndOldWorkspaceASRDoNotReachConsumers() {
        let (bridge, route) = makeSUT(); bridge.start()
        let accepted = publication("accepted")
        route.emitTranscript(accepted)
        route.emitTranscript(accepted)
        route.emitTranscript(publication("forged", sourceID: UUID()))
        route.emitTranscript(publication("stale", fence: .init(revision: 6)))
        route.emitTranscript(publication("old", workspace: outsideWorkspace))
        XCTAssertEqual(route.acceptedTranscriptAttemptIDs, [accepted.identity.attemptID])
        route.emitLibraryCommit(committed(accepted))
        XCTAssertEqual(route.miTranscriptAttemptIDs, [accepted.identity.attemptID])
    }

    func testTranscriptEditMarksMIStaleOnceAndNeverStartsJobs() {
        let (bridge, route) = makeSUT(); bridge.start()
        let event = edited("edit")
        route.emitTranscriptEdit(event)
        XCTAssertEqual(route.miStaleSessions, [session.id])
        XCTAssertTrue(route.transcriptionStarts.isEmpty)
        XCTAssertEqual(route.indexedTranscriptRevisions, [event.identity.transcriptRevision])
    }

    func testMIDurablePublicationReloadsLibraryOnceAndNeverRestartsASR() {
        let (bridge, route) = makeSUT(); bridge.start()
        let event = miPublication("mi")
        route.emitMeetingIntelligence(event); route.emitMeetingIntelligence(event)
        XCTAssertEqual(route.miRefreshes.map(\.0), [session.id])
        XCTAssertEqual(route.miRefreshes.map(\.1), [currentFence])
        XCTAssertTrue(route.transcriptionStarts.isEmpty)
    }

    func testEligibleAndIneligibleImportsRetainBothButStartOnlyEligibleASR() {
        let (bridge, route) = makeSUT(); bridge.start()
        route.transcriptionProviderConfigured = true
        route.emitImport(.init(identity: libraryIdentity("import-1", session: session), canonicalSession: session))
        route.transcriptionProviderConfigured = false
        route.emitImport(.init(identity: libraryIdentity("import-2", session: otherSession), canonicalSession: otherSession))
        XCTAssertEqual(route.retainedImports, [session.id, otherSession.id])
        XCTAssertEqual(route.transcriptionStarts, [session.id])
        XCTAssertEqual(route.providerRecoverySessions, [otherSession.id])
        XCTAssertEqual(route.importStatuses, [
            "Audio imported for transcription: \(session.displayName)",
            "Audio imported for transcription: \(otherSession.displayName)"
        ])
    }

    func testTrashFansOutOnlyAfterLibraryTombstone() {
        let (bridge, route) = makeSUT(); bridge.start()
        route.emitRemoval(.init(identity: libraryIdentity("trash", session: session)))
        XCTAssertEqual(route.tombstonedSessions, [session.id])
        XCTAssertEqual(route.playbackStops, [session.id])
        XCTAssertEqual(route.transcriptionRemovals, [session.id])
        XCTAssertEqual(route.miRemovals, [session.id])
    }

    func testWorkspaceChangeIsDirectAppModelIngressAndUsesApprovedOrder() {
        let (bridge, route) = makeSUT(); bridge.start()
        bridge.workspaceDidChange(.init(workspace: .init(folder: workspace, fence: currentFence)))
        XCTAssertEqual(route.workspaceCalls, [PRBFeatureBridgeRouteRecorder.WorkspaceCall.advanceASR(currentFence), .clearLibrary, .resetMI, .clearASR, .refreshLibrary(workspace, currentFence)])
        XCTAssertEqual(route.currentWorkspaceReadCount, 1)
    }

    func testProviderSaveOnlyChangesFutureAttemptConfiguration() {
        let (bridge, route) = makeSUT(); bridge.start()
        route.activeASRProviderSnapshot = "A"; route.activeMIProviderSnapshot = "A"
        let saved = ProviderSettingsSaved(profileRevision: UUID())
        route.emitProviderSave(saved)
        XCTAssertEqual(route.providerSaveEvents, [saved])
        XCTAssertEqual(route.activeASRProviderSnapshot, "A")
        XCTAssertEqual(route.activeMIProviderSnapshot, "A")
        XCTAssertEqual(route.nextProviderRevision, saved.profileRevision)
    }

    func testFinalizationIsDirectAppModelIngressAndDedupesMetadataWarning() {
        let (bridge, route) = makeSUT(); bridge.start()
        let outcome = finalization(folder: session.folderURL, fence: currentFence, metadata: .warning("metadata"))
        bridge.recordingDidFinalize(outcome); bridge.recordingDidFinalize(outcome)
        XCTAssertEqual(route.finalizationIDs, [outcome.finalizationID])
    }

    func testFinalizationAdmitsNewSessionBeforeLibraryHasLoadedIt() {
        let (bridge, route) = makeSUT(); bridge.start()
        route.hideCanonicalSession(session.id)
        let outcome = finalization(
            folder: session.folderURL,
            fence: currentFence,
            metadata: .saved
        )

        bridge.recordingDidFinalize(outcome)

        XCTAssertEqual(route.finalizationIDs, [outcome.finalizationID])
    }

    func testForgedOrObsoleteFinalizationDoesNotRefreshVisibleLibrary() {
        let (bridge, route) = makeSUT(); bridge.start()
        bridge.recordingDidFinalize(finalization(folder: outsideWorkspace, fence: currentFence, metadata: .saved))
        bridge.recordingDidFinalize(finalization(folder: session.folderURL, fence: .init(revision: 2), metadata: .saved))
        XCTAssertTrue(route.finalizationIDs.isEmpty)
    }

    func testLibraryLoadedAndMetadataCallbacksUseRealTypedContracts() {
        let (bridge, route) = makeSUT(); bridge.start()
        let states = [session.id: TranscriptionState(phase: .completed, message: "done", startedAt: .distantPast, finishedAt: .distantPast)]
        route.emitSessionsLoaded(.init(sessions: [session], transcriptionStates: states))
        route.emitMetadataSaved(.init(identity: libraryIdentity("metadata", session: session), canonicalSession: session))
        XCTAssertEqual(route.loadedStates, [states])
        XCTAssertEqual(route.miReloads, [[session.id], [session.id]])
        XCTAssertEqual(route.metadataEvents, [session.id])
    }

    func testShutdownClosesAdmissionAndUnregistersEveryProducer() {
        let (bridge, route) = makeSUT(); bridge.start(); bridge.shutdown(); bridge.shutdown()
        route.emitTranscript(publication("late"))
        route.emitMeetingIntelligence(miPublication("late-mi"))
        route.emitMetadataSaved(.init(identity: libraryIdentity("late-meta", session: session), canonicalSession: session))
        XCTAssertEqual(route.unregistrationCount, 9)
        XCTAssertTrue(route.allConsumerCommandsAreEmpty)
    }

    func testCapturedCallbackAfterShutdownHasNoConsumerVisibleEffect() {
        let (bridge, route) = makeSUT(); bridge.start()
        let callback = route.captureTranscriptCallback()
        bridge.shutdown()
        callback(publication("captured-late"))
        XCTAssertTrue(route.allConsumerCommandsAreEmpty)
    }

    func testDurableTranscriptPublicationAdmittedBeforeReentrantShutdownSettlesAtMostOnce() {
        let (bridge, route) = makeSUT(); bridge.start()
        let callback = route.captureTranscriptCallback()
        let event = publication("durable-before-shutdown")
        route.onTranscriptAccepted = { bridge.shutdown() }

        callback(event)
        callback(event)

        XCTAssertEqual(
            route.acceptedTranscriptAttemptIDs,
            [event.identity.attemptID]
        )
        XCTAssertTrue(route.miTranscriptAttemptIDs.isEmpty)
    }

    func testBridgeShutdownBeforeStartIsTerminal() {
        let (bridge, route) = makeSUT()

        bridge.shutdown()
        bridge.shutdown()
        bridge.start()
        route.emitTranscript(publication("late"))
        bridge.recordingDidFinalize(
            finalization(
                folder: session.folderURL,
                fence: currentFence,
                metadata: .saved
            )
        )

        XCTAssertEqual(route.registrationCount, 0)
        XCTAssertTrue(route.allConsumerCommandsAreEmpty)
    }

    func testOldBridgeShutdownDoesNotRemoveReplacementBridgeObservers() {
        let model = AppModel(performStartupWork: false)
        defer { model.shutdown() }
        let boundaries = PRBFeatureBoundaries(
            library: model.libraryFeature,
            transcription: model.transcriptionFeature,
            meetingIntelligence: model.meetingIntelligenceFeature,
            playback: model.playbackFeature
        )
        let makeBridge = {
            PRBFeatureBridge(
                boundaries: boundaries,
                providerSettings: model.aiProviderSettingsModel,
                currentWorkspace: {
                    .init(folder: model.outputFolder, fence: .initial)
                },
                transcriptionProviderIsConfigured: { false },
                reportStatus: { _ in }
            )
        }
        let oldBridge = makeBridge()
        let replacementBridge = makeBridge()
        oldBridge.start()
        replacementBridge.start()

        oldBridge.shutdown()

        XCTAssertNotNil(model.transcriptionFeature.onSuccessfulPublication)
        XCTAssertNotNil(model.libraryFeature.onSessionsLoaded)
        XCTAssertNotNil(model.libraryFeature.onTranscriptPublicationCommitted)
        XCTAssertNotNil(model.libraryFeature.onTranscriptEdited)
        XCTAssertNotNil(model.libraryFeature.onMetadataSaved)
        XCTAssertNotNil(model.libraryFeature.onImportedAudioReady)
        XCTAssertNotNil(model.libraryFeature.onSessionRemoved)
        XCTAssertNotNil(model.meetingIntelligenceFeature.onPublished)
        XCTAssertNotNil(model.aiProviderSettingsModel.onProviderSettingsSaved)

        replacementBridge.shutdown()
        XCTAssertNil(model.transcriptionFeature.onSuccessfulPublication)
        XCTAssertNil(model.libraryFeature.onSessionsLoaded)
        XCTAssertNil(model.libraryFeature.onTranscriptPublicationCommitted)
        XCTAssertNil(model.libraryFeature.onTranscriptEdited)
        XCTAssertNil(model.libraryFeature.onMetadataSaved)
        XCTAssertNil(model.libraryFeature.onImportedAudioReady)
        XCTAssertNil(model.libraryFeature.onSessionRemoved)
        XCTAssertNil(model.meetingIntelligenceFeature.onPublished)
        XCTAssertNil(model.aiProviderSettingsModel.onProviderSettingsSaved)
    }

    func testShutdownIsTerminalAndTombstoneMustPrecedeRemovalFanout() {
        let (bridge, route) = makeSUT(); bridge.start(); bridge.shutdown(); bridge.start()
        route.emitRemoval(.init(identity: libraryIdentity("not-tombstoned", session: session)))
        XCTAssertTrue(route.playbackStops.isEmpty)
        XCTAssertTrue(route.transcriptionRemovals.isEmpty)
    }

    private func makeSUT() -> (PRBFeatureBridge, PRBFeatureBridgeRouteRecorder) {
        let route = PRBFeatureBridgeRouteRecorder(currentWorkspace: .init(folder: workspace, fence: currentFence))
        return (PRBFeatureBridge(routes: route.routes), route)
    }
}

private let workspace = URL(fileURLWithPath: "/private/tmp/prb-bridge-workspace", isDirectory: true)
private let outsideWorkspace = URL(fileURLWithPath: "/private/tmp/prb-bridge-outside", isDirectory: true)
private let currentFence = WorkspacePublicationFence(revision: 7)
private let transcriptionSourceID = UUID()
private let librarySourceID = UUID()
private let miSourceID = UUID()
private let session = bridgeSession("session")
private let otherSession = bridgeSession("other")

private func bridgeSession(_ name: String) -> RecordingSession {
    let folder = workspace.appendingPathComponent(name, isDirectory: true)
    return .init(id: folder, folderURL: folder, recordingURL: folder.appendingPathComponent("recording.m4a"), createdAt: .distantPast, duration: 1, fileSize: 1, metadata: .init())
}

private func libraryIdentity(_ name: String, session: RecordingSession, fence: WorkspacePublicationFence = currentFence, revision: TranscriptDocumentRevision? = nil) -> LibraryMutationIdentity {
    .init(librarySourceID: librarySourceID, mutationID: UUID(), sessionID: session.id, normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL), transcriptRevision: revision ?? .init(sha256: name, byteCount: 1), workspaceFence: fence)
}

private func publication(_ name: String, sourceID: UUID = transcriptionSourceID, fence: WorkspacePublicationFence = currentFence, workspace folderWorkspace: URL = workspace) -> TranscriptPublished {
    let publishedSession = folderWorkspace == workspace ? session : .init(id: folderWorkspace.appendingPathComponent("old"), folderURL: folderWorkspace.appendingPathComponent("old"), recordingURL: folderWorkspace.appendingPathComponent("old/recording.m4a"), createdAt: .distantPast, duration: 1, fileSize: 1, metadata: .init())
    return .init(session: publishedSession, canonicalURL: publishedSession.folderURL.appendingPathComponent("transcript.txt"), revision: .init(sha256: name, byteCount: 1), normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(publishedSession.folderURL), identity: .init(coordinatorInstanceID: sourceID, generation: 1, attemptID: UUID()), workspaceFence: fence)
}

private func committed(_ event: TranscriptPublished) -> LibraryTranscriptProjectionCommitted {
    .init(identity: libraryIdentity("committed", session: event.session, fence: event.workspaceFence, revision: event.revision), publication: event, canonicalSession: event.session)
}

private func edited(_ name: String) -> TranscriptEdited {
    .init(identity: libraryIdentity(name, session: session), canonicalSession: session)
}

private func miPublication(_ name: String) -> MeetingIntelligencePublished {
    .init(identity: .init(coordinatorInstanceID: miSourceID, sessionID: session.id, normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL), generation: 1, attemptID: UUID(), transcriptRevision: .init(sha256: name, byteCount: 1), workspaceFence: currentFence, kind: .artifactAndAutomaticTitle), canonicalSession: session, artifact: nil, titleOutcome: .preserved)
}

private func finalization(folder: URL, fence: WorkspacePublicationFence, metadata: RecordingSourceMetadataPublicationOutcome) -> RecordingFinalizationOutcome {
    .init(finalizationID: UUID(), folder: folder, workspaceFence: fence, recordingURL: folder.appendingPathComponent("recording.m4a"), health: .init(), metadataOutcome: metadata, source: .manual)
}

@MainActor
private final class PRBFeatureBridgeRouteRecorder {
    enum WorkspaceCall: Equatable { case advanceASR(WorkspacePublicationFence), clearLibrary, resetMI, clearASR, refreshLibrary(URL, WorkspacePublicationFence) }
    var currentWorkspace: LibraryWorkspaceSnapshot
    var transcriptionProviderConfigured = true
    var activeASRProviderSnapshot: String?
    var activeMIProviderSnapshot: String?
    private(set) var nextProviderRevision: UUID?
    private(set) var currentWorkspaceReadCount = 0
    private(set) var registrationCount = 0
    private(set) var unregistrationCount = 0
    var onTranscriptAccepted: (() -> Void)?
    private(set) var acceptedTranscriptAttemptIDs: [UUID] = [] {
        didSet { onTranscriptAccepted?() }
    }
    private(set) var miTranscriptAttemptIDs: [UUID] = []
    private(set) var miStaleSessions: [RecordingSession.ID] = []
    private(set) var indexedTranscriptRevisions: [TranscriptDocumentRevision?] = []
    private(set) var miRefreshes: [(RecordingSession.ID, WorkspacePublicationFence)] = []
    private(set) var transcriptionStarts: [RecordingSession.ID] = []
    private(set) var providerRecoverySessions: [RecordingSession.ID] = []
    private(set) var retainedImports: [RecordingSession.ID] = []
    private(set) var importStatuses: [String] = []
    private(set) var tombstonedSessions: [RecordingSession.ID] = []
    private(set) var playbackStops: [RecordingSession.ID] = []
    private(set) var transcriptionRemovals: [RecordingSession.ID] = []
    private(set) var miRemovals: [RecordingSession.ID] = []
    private(set) var workspaceCalls: [WorkspaceCall] = []
    private(set) var providerSaveEvents: [ProviderSettingsSaved] = []
    private(set) var finalizationIDs: [UUID] = []
    private(set) var loadedStates: [[RecordingSession.ID: TranscriptionState]] = []
    private(set) var metadataEvents: [RecordingSession.ID] = []
    private(set) var miReloads: [[RecordingSession.ID]] = []
    private var tombstonedCanonicalIDs: Set<RecordingSession.ID> = []
    private var hiddenCanonicalIDs: Set<RecordingSession.ID> = []
    private var transcript: ((TranscriptPublished) -> Void)?; private var commit: ((LibraryTranscriptProjectionCommitted) -> Void)?; private var edit: ((TranscriptEdited) -> Void)?; private var metadata: ((MetadataSaved) -> Void)?; private var loaded: ((LibraryLoadedSnapshot) -> Void)?; private var imported: ((ImportedAudioSessionReady) -> Void)?; private var removed: ((SessionRemoved) -> Void)?; private var mi: ((MeetingIntelligencePublished) -> Void)?; private var provider: ((ProviderSettingsSaved) -> Void)?
    init(currentWorkspace: LibraryWorkspaceSnapshot) { self.currentWorkspace = currentWorkspace }
    var allConsumerCommandsAreEmpty: Bool { acceptedTranscriptAttemptIDs.isEmpty && miTranscriptAttemptIDs.isEmpty && miStaleSessions.isEmpty && miRefreshes.isEmpty && transcriptionStarts.isEmpty && playbackStops.isEmpty && transcriptionRemovals.isEmpty && miRemovals.isEmpty && workspaceCalls.isEmpty && providerSaveEvents.isEmpty && finalizationIDs.isEmpty && miReloads.isEmpty }
    var routes: PRBFeatureBridge.Routes {
        .init(currentWorkspace: { [weak self] in guard let self else { return nil }; self.currentWorkspaceReadCount += 1; return self.currentWorkspace }, canonicalSession: { [weak self] id in guard let self, !self.tombstonedCanonicalIDs.contains(id), !self.hiddenCanonicalIDs.contains(id) else { return nil }; return [session, otherSession].first { $0.id == id } }, expectedTranscriptionPublicationSourceID: transcriptionSourceID, expectedLibrarySourceID: librarySourceID, expectedMeetingIntelligencePublicationSourceID: miSourceID, transcriptionProviderIsConfigured: { [weak self] in self?.transcriptionProviderConfigured ?? false }, registerTranscriptPublication: { [weak self] h in self?.register(\.transcript, h) ?? {} }, registerLibrarySessionsLoaded: { [weak self] h in self?.register(\.loaded, h) ?? {} }, registerLibraryTranscriptCommit: { [weak self] h in self?.register(\.commit, h) ?? {} }, registerTranscriptEdit: { [weak self] h in self?.register(\.edit, h) ?? {} }, registerMetadataSaved: { [weak self] h in self?.register(\.metadata, h) ?? {} }, registerImportedAudio: { [weak self] h in self?.register(\.imported, h) ?? {} }, registerSessionRemoval: { [weak self] h in self?.register(\.removed, h) ?? {} }, registerMeetingIntelligencePublication: { [weak self] h in self?.register(\.mi, h) ?? {} }, registerProviderSave: { [weak self] h in self?.register(\.provider, h) ?? {} }, acceptTranscriptPublication: { [weak self] in self?.acceptedTranscriptAttemptIDs.append($0.identity.attemptID) }, handleCommittedTranscriptPublication: { [weak self] in self?.miTranscriptAttemptIDs.append($0.identity.attemptID) }, markTranscriptStale: { [weak self] in self?.miStaleSessions.append($0.id) }, refreshAfterMeetingIntelligence: { [weak self] s, f in self?.miRefreshes.append((s.id, f)) }, startTranscription: { [weak self] s, configured in guard let self else { return }; self.retainedImports.append(s.id); configured ? self.transcriptionStarts.append(s.id) : self.providerRecoverySessions.append(s.id) }, reportStatus: { [weak self] in self?.importStatuses.append($0) }, stopPlaybackIfActive: { [weak self] in self?.playbackStops.append($0) }, removeTranscriptionProjection: { [weak self] in self?.transcriptionRemovals.append($0) }, cancelAndRemoveMeetingIntelligence: { [weak self] in self?.miRemovals.append($0) }, replaceLoadedTranscriptionStates: { [weak self] in self?.loadedStates.append($0) }, reloadMeetingIntelligenceSessions: { [weak self] in self?.miReloads.append($0.map(\.id)) }, clearLibraryForWorkspaceChange: { [weak self] in self?.workspaceCalls.append(.clearLibrary) }, refreshLibrary: { [weak self] u, f in self?.workspaceCalls.append(.refreshLibrary(u, f)) }, advanceTranscriptionFence: { [weak self] in self?.workspaceCalls.append(.advanceASR($0)) }, resetMeetingIntelligenceForWorkspaceChange: { [weak self] in self?.workspaceCalls.append(.resetMI) }, clearTranscriptionProjections: { [weak self] in self?.workspaceCalls.append(.clearASR) }, providerSettingsSaved: { [weak self] e in self?.providerSaveEvents.append(e); self?.nextProviderRevision = e.profileRevision }, acceptRecordingFinalization: { [weak self] in self?.finalizationIDs.append($0.finalizationID) })
    }
    func emitTranscript(_ e: TranscriptPublished) { transcript?(e) }; func emitLibraryCommit(_ e: LibraryTranscriptProjectionCommitted) { commit?(e) }; func emitTranscriptEdit(_ e: TranscriptEdited) { indexedTranscriptRevisions.append(e.identity.transcriptRevision); edit?(e) }; func emitMetadataSaved(_ e: MetadataSaved) { metadataEvents.append(e.canonicalSession.id); metadata?(e) }; func emitSessionsLoaded(_ e: LibraryLoadedSnapshot) { loaded?(e) }; func emitMeetingIntelligence(_ e: MeetingIntelligencePublished) { mi?(e) }; func emitImport(_ e: ImportedAudioSessionReady) { imported?(e) }; func emitRemoval(_ e: SessionRemoved) { tombstonedCanonicalIDs.insert(e.identity.sessionID); tombstonedSessions.append(e.identity.sessionID); removed?(e) }; func emitProviderSave(_ e: ProviderSettingsSaved) { provider?(e) }
    func captureTranscriptCallback() -> (TranscriptPublished) -> Void { transcript! }
    func hideCanonicalSession(_ id: RecordingSession.ID) { hiddenCanonicalIDs.insert(id) }
    private func register<Event>(_ keyPath: ReferenceWritableKeyPath<PRBFeatureBridgeRouteRecorder, ((Event) -> Void)?>, _ handler: @escaping (Event) -> Void) -> () -> Void { registrationCount += 1; self[keyPath: keyPath] = handler; return { [weak self] in guard let self else { return }; self[keyPath: keyPath] = nil; self.unregistrationCount += 1 } }
}
