import Combine
import XCTest
@testable import RecorderApp

@MainActor
final class AppModelLibraryFeatureIntegrationTests: XCTestCase {
    func testAppModelRetainsExactlyTheInjectedLibraryFeatureInstance() {
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in true }
        )
        let model = AppModel(performStartupWork: false, libraryFeature: feature)
        XCTAssertTrue(model.libraryFeature === feature)
    }

    func testInjectedLibraryGateIsTheOnlyGateUsedByAppModel() {
        let gate = RecordingSessionMutationGate()
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in true }, mutationGate: gate
        )
        let model = AppModel(performStartupWork: false, libraryFeature: feature)
        XCTAssertTrue(model.transcriptMutationGate === gate)
        XCTAssertTrue(model.libraryFeature.mutationGate === model.transcriptMutationGate)
    }

    func testAppModelSessionsIsReadOnlyProjectionOfLibrarySnapshot() {
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in true }
        )
        let model = AppModel(performStartupWork: false, libraryFeature: feature)
        XCTAssertEqual(model.sessions, feature.sessions)
    }

    func testLibraryPublicationDoesNotRepublishAppModel() async {
        let session = LibraryFeatureFixture.session(named: "publication")
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [session] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in true }
        )
        let model = AppModel(performStartupWork: false, libraryFeature: feature)
        var publications = 0
        let cancellable = model.objectWillChange.sink { publications += 1 }
        let libraryPublished = expectation(description: "library published")
        let libraryCancellable = feature.$snapshot.dropFirst().sink { snapshot in
            guard snapshot.sessions == [session] else { return }
            libraryPublished.fulfill()
        }
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [libraryPublished], timeout: 1)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
        withExtendedLifetime(libraryCancellable) {}
    }

    func testIndexedImportedAudioStartsASROnceAndStaleOrFailedImportStartsNone() async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        try Data([1]).write(to: source)
        let imported = RecordingSession(
            id: root.appendingPathComponent("imported", isDirectory: true),
            folderURL: root.appendingPathComponent("imported", isDirectory: true),
            recordingURL: root.appendingPathComponent("imported/recording.m4a"),
            createdAt: .now, duration: 0, fileSize: 1, metadata: .init()
        )
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in true }, audioImporter: { _, _ in imported }
        )
        let preparationStarted = expectation(description: "imported session reaches ASR preparation")
        let preparer = ImportCountingPreparer(onPrepare: { preparationStarted.fulfill() })
        let model = AppModel(
            providerRepository: ImportTestProvider(),
            inputDevices: { [] }, defaultInputDeviceID: { nil },
            performStartupWork: false, initialOutputFolder: root,
            transcriptionAudioPreparer: preparer,
            libraryFeature: feature
        )
        model.aiProviderSettingsModel.reload()
        model.seedLibrarySessionsForTesting([])

        guard case .success = await feature.importAudio(
            source, workspace: root, fence: .initial
        ) else { return XCTFail("indexed import should succeed") }
        await fulfillment(of: [preparationStarted], timeout: 1)
        XCTAssertEqual(preparer.requestCount, 1)

        let nextWorkspace = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: nextWorkspace) }
        model.setOutputFolder(nextWorkspace)
        guard case .failure = await feature.importAudio(
            source, workspace: root, fence: .initial
        ) else { return XCTFail("old workspace import must fail") }
        XCTAssertEqual(preparer.requestCount, 1)

        let failing = LibraryFeatureModel(
            sessionLoader: { _ in [] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in true }, audioImporter: { _, _ in throw ImportTestError.failed }
        )
        let failingModel = AppModel(
            providerRepository: ImportTestProvider(), inputDevices: { [] },
            defaultInputDeviceID: { nil }, performStartupWork: false,
            initialOutputFolder: nextWorkspace,
            transcriptionAudioPreparer: preparer, libraryFeature: failing
        )
        failingModel.aiProviderSettingsModel.reload()
        failingModel.seedLibrarySessionsForTesting([])
        guard case .failure = await failing.importAudio(
            source, workspace: nextWorkspace, fence: .initial
        ) else { return XCTFail("failed import must fail") }
        XCTAssertEqual(preparer.requestCount, 1)
    }

    func testForgedImportedAudioEventsRequireCurrentCanonicalLibraryAdmission() async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeDiskSession(in: root, name: "canonical")
        let feature = makeFeature(session: session)
        let admittedToASR = expectation(description: "only genuine imported event reaches ASR")
        let preparer = ImportCountingPreparer(onPrepare: { admittedToASR.fulfill() })
        let model = AppModel(
            providerRepository: ImportTestProvider(), inputDevices: { [] },
            defaultInputDeviceID: { nil }, performStartupWork: false,
            initialOutputFolder: root, transcriptionAudioPreparer: preparer,
            libraryFeature: feature
        )
        model.aiProviderSettingsModel.reload()
        model.seedLibrarySessionsForTesting([session])
        defer { model.shutdown() }

        let genuineIdentity = libraryIdentity(for: session, feature: feature)
        let foreignIdentity = LibraryMutationIdentity(
            librarySourceID: UUID(), mutationID: UUID(), sessionID: session.id,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
            transcriptRevision: nil, workspaceFence: .initial
        )
        let staleIdentity = LibraryMutationIdentity(
            librarySourceID: feature.librarySourceID, mutationID: UUID(), sessionID: session.id,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
            transcriptRevision: nil, workspaceFence: .initial.advanced()
        )
        let wrongSessionIdentity = LibraryMutationIdentity(
            librarySourceID: feature.librarySourceID, mutationID: UUID(),
            sessionID: root.appendingPathComponent("forged-session"),
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
            transcriptRevision: nil, workspaceFence: .initial
        )
        let wrongFolderIdentity = LibraryMutationIdentity(
            librarySourceID: feature.librarySourceID, mutationID: UUID(), sessionID: session.id,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(
                root.appendingPathComponent("forged-folder")
            ),
            transcriptRevision: nil, workspaceFence: .initial
        )
        var alteredMetadata = session.metadata
        alteredMetadata.title = "forged canonical payload"
        let differentCanonicalPayload = RecordingSession(
            id: session.id, folderURL: session.folderURL, recordingURL: session.recordingURL,
            createdAt: session.createdAt, duration: session.duration, fileSize: session.fileSize,
            metadata: alteredMetadata, searchDocument: session.searchDocument
        )
        let noncanonical = try makeDiskSession(in: root, name: "not-indexed")
        let noncanonicalIdentity = libraryIdentity(for: noncanonical, feature: feature)

        for event in [
            ImportedAudioSessionReady(identity: foreignIdentity, canonicalSession: session),
            ImportedAudioSessionReady(identity: staleIdentity, canonicalSession: session),
            ImportedAudioSessionReady(identity: wrongSessionIdentity, canonicalSession: session),
            ImportedAudioSessionReady(identity: wrongFolderIdentity, canonicalSession: session),
            ImportedAudioSessionReady(identity: genuineIdentity, canonicalSession: differentCanonicalPayload),
            ImportedAudioSessionReady(identity: noncanonicalIdentity, canonicalSession: noncanonical)
        ] {
            feature.onImportedAudioReady?(event)
            XCTAssertNil(
                model.transcribingSessionID,
                "A forged import must not synchronously acquire the ASR job."
            )
            XCTAssertEqual(preparer.requestCount, 0, "forged import must not reach ASR")
        }

        feature.onImportedAudioReady?(.init(
            identity: genuineIdentity, canonicalSession: session
        ))
        XCTAssertEqual(
            model.transcribingSessionID,
            session.id,
            "The genuine canonical event must synchronously acquire the ASR job."
        )
        await fulfillment(of: [admittedToASR], timeout: 1)
        XCTAssertEqual(preparer.requestCount, 1)
    }

    func testForeignStaleAndNoncanonicalLibraryCallbacksDoNotStartMeetingIntelligence() async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeDiskSession(in: root, name: "canonical")
        try "canonical transcript".write(
            to: session.folderURL.appendingPathComponent("transcript.txt"),
            atomically: true, encoding: .utf8
        )
        let feature = makeFeature(session: session)
        let reader = CountingTranscriptReader()
        let availabilityReached = expectation(
            description: "only genuine transcript publication reaches availability"
        )
        let availability = CountingAvailability(onAvailability: {
            availabilityReached.fulfill()
        })
        var coordinator: MeetingIntelligenceJobCoordinator!
        let model = AppModel(
            providerRepository: ImportTestProvider(),
            performStartupWork: false, initialOutputFolder: root,
            libraryFeature: feature,
            meetingIntelligenceFeatureFactory: { repository, sourceID, gate in
                let artifacts = MeetingIntelligenceArtifactStore(mutationGate: gate)
                coordinator = MeetingIntelligenceJobCoordinator(
                    providerRepository: repository,
                    expectedPublicationSourceID: sourceID,
                    mutationGate: gate,
                    transcriptReader: reader,
                    availabilityChecker: availability,
                    generator: NeverGeneratingMeetingIntelligence(),
                    publisher: MeetingIntelligencePublisher(
                        mutationGate: gate, artifactStore: artifacts
                    ),
                    artifactStore: artifacts,
                    stateStore: MeetingIntelligenceStateStore(mutationGate: gate)
                )
                return MeetingIntelligenceFeatureModel(coordinator: coordinator)
            }
        )
        model.seedLibrarySessionsForTesting([session])
        let snapshot = try SecureTranscriptDocumentReader().readCanonical(
            in: session.folderURL, allowLegacy: false
        )
        let publication = TranscriptPublished(
            session: session,
            canonicalURL: snapshot.url,
            revision: snapshot.revision,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
            identity: .init(
                coordinatorInstanceID: model.transcriptionFeature.publicationSourceID,
                generation: 1, attemptID: UUID()
            ),
            workspaceFence: .initial
        )
        let foreignIdentity = LibraryMutationIdentity(
            librarySourceID: UUID(), mutationID: UUID(), sessionID: session.id,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
            transcriptRevision: publication.revision, workspaceFence: .initial
        )
        let staleIdentity = LibraryMutationIdentity(
            librarySourceID: feature.librarySourceID, mutationID: UUID(),
            sessionID: session.id,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
            transcriptRevision: publication.revision,
            workspaceFence: .initial.advanced()
        )
        let noncanonical = try makeDiskSession(in: root, name: "not-indexed")
        try "noncanonical transcript".write(
            to: noncanonical.folderURL.appendingPathComponent("transcript.txt"),
            atomically: true, encoding: .utf8
        )
        let noncanonicalSnapshot = try SecureTranscriptDocumentReader().readCanonical(
            in: noncanonical.folderURL, allowLegacy: false
        )
        let noncanonicalIdentity = LibraryMutationIdentity(
            librarySourceID: feature.librarySourceID, mutationID: UUID(),
            sessionID: noncanonical.id,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(noncanonical.folderURL),
            transcriptRevision: noncanonicalSnapshot.revision, workspaceFence: .initial
        )
        let revisionMismatchIdentity = LibraryMutationIdentity(
            librarySourceID: feature.librarySourceID, mutationID: UUID(),
            sessionID: session.id,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
            transcriptRevision: .init(
                sha256: "different-revision", byteCount: publication.revision.byteCount
            ),
            workspaceFence: .initial
        )
        let publicationWithDifferentSessionPayload = TranscriptPublished(
            session: RecordingSession(
                id: session.id, folderURL: session.folderURL,
                recordingURL: root.appendingPathComponent("forged-recording.m4a"),
                createdAt: session.createdAt,
                duration: session.duration, fileSize: session.fileSize,
                metadata: session.metadata, searchDocument: session.searchDocument
            ),
            canonicalURL: publication.canonicalURL, revision: publication.revision,
            normalizedSessionFolder: publication.normalizedSessionFolder,
            identity: publication.identity, workspaceFence: publication.workspaceFence
        )
        let publicationWithUpdatedSearchDocument = TranscriptPublished(
            session: RecordingSession(
                id: session.id, folderURL: session.folderURL,
                recordingURL: session.recordingURL, createdAt: session.createdAt,
                duration: session.duration, fileSize: session.fileSize,
                metadata: session.metadata,
                searchDocument: .init(metadataText: "updated metadata", transcriptText: "updated transcript")
            ),
            canonicalURL: publication.canonicalURL, revision: publication.revision,
            normalizedSessionFolder: publication.normalizedSessionFolder,
            identity: publication.identity, workspaceFence: publication.workspaceFence
        )
        let publicationWithDifferentFolder = TranscriptPublished(
            session: session, canonicalURL: publication.canonicalURL,
            revision: publication.revision,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(
                root.appendingPathComponent("forged-publication-folder")
            ),
            identity: publication.identity, workspaceFence: publication.workspaceFence
        )

        feature.onTranscriptPublicationCommitted?(.init(
            identity: foreignIdentity, publication: publication, canonicalSession: session
        ))
        await coordinator.waitUntilIdleForTesting(sessionID: session.id)
        XCTAssertEqual(reader.count, 0)
        XCTAssertEqual(availability.count, 0)

        feature.onTranscriptPublicationCommitted?(.init(
            identity: libraryIdentity(
                for: session, feature: feature, transcriptRevision: publication.revision
            ),
            publication: publicationWithDifferentSessionPayload,
            canonicalSession: session
        ))
        XCTAssertEqual(reader.count, 0)
        XCTAssertEqual(availability.count, 0)

        feature.onTranscriptPublicationCommitted?(.init(
            identity: libraryIdentity(
                for: session, feature: feature, transcriptRevision: publication.revision
            ),
            publication: publicationWithDifferentFolder,
            canonicalSession: session
        ))
        XCTAssertEqual(reader.count, 0)
        XCTAssertEqual(availability.count, 0)

        feature.onTranscriptPublicationCommitted?(.init(
            identity: revisionMismatchIdentity,
            publication: publication,
            canonicalSession: session
        ))
        await coordinator.waitUntilIdleForTesting(sessionID: session.id)
        XCTAssertEqual(reader.count, 0)
        XCTAssertEqual(availability.count, 0)

        feature.onTranscriptEdited?(.init(
            identity: staleIdentity, canonicalSession: session
        ))
        await coordinator.waitUntilIdleForTesting(sessionID: session.id)
        XCTAssertEqual(reader.count, 0)
        XCTAssertEqual(availability.count, 0)

        feature.onTranscriptPublicationCommitted?(.init(
            identity: noncanonicalIdentity,
            publication: .init(
                session: noncanonical,
                canonicalURL: noncanonicalSnapshot.url,
                revision: noncanonicalSnapshot.revision,
                normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(
                    noncanonical.folderURL
                ),
                identity: .init(
                    coordinatorInstanceID: model.transcriptionFeature.publicationSourceID,
                    generation: 2, attemptID: UUID()
                ),
                workspaceFence: .initial
            ),
            canonicalSession: noncanonical
        ))
        await coordinator.waitUntilIdleForTesting(sessionID: noncanonical.id)

        XCTAssertEqual(reader.count, 0)
        XCTAssertEqual(availability.count, 0)

        feature.onTranscriptPublicationCommitted?(.init(
            identity: libraryIdentity(
                for: session, feature: feature, transcriptRevision: publication.revision
            ),
            publication: publicationWithUpdatedSearchDocument, canonicalSession: session
        ))
        await coordinator.waitUntilIdleForTesting(sessionID: session.id)
        XCTAssertEqual(reader.count, 0)
        XCTAssertEqual(availability.count, 0)

        model.transcriptionFeature.onSuccessfulPublication?(
            publicationWithUpdatedSearchDocument
        )
        await fulfillment(of: [availabilityReached], timeout: 1)
        await coordinator.waitUntilIdleForTesting(sessionID: session.id)
        XCTAssertEqual(reader.count, 1)
        XCTAssertEqual(availability.count, 1)
        let genuinePresentation = model.meetingIntelligencePresentation(
            for: session
        )
        XCTAssertEqual(
            genuinePresentation.unavailableReason,
            .connectionFailed
        )

        let stateStore = MeetingIntelligenceStateStore(
            mutationGate: RecordingSessionMutationGate()
        )
        let interrupted = MeetingIntelligenceState(
            schemaVersion: MeetingIntelligenceState.currentSchemaVersion,
            phase: .interrupted,
            message: "interrupted", sourceTranscriptSHA256: nil,
            startedAt: .now, finishedAt: .now
        )
        try stateStore.save(interrupted, in: session.folderURL)
        try stateStore.save(interrupted, in: noncanonical.folderURL)
        feature.onMetadataSaved?(.init(
            identity: foreignIdentity, canonicalSession: session
        ))
        await coordinator.waitUntilIdleForTesting(sessionID: session.id)
        XCTAssertEqual(
            model.meetingIntelligencePresentation(for: session),
            genuinePresentation
        )

        feature.onMetadataSaved?(.init(
            identity: noncanonicalIdentity, canonicalSession: noncanonical
        ))
        await coordinator.waitUntilIdleForTesting(sessionID: noncanonical.id)
        XCTAssertEqual(model.meetingIntelligencePresentation(for: noncanonical), .empty)

        XCTAssertEqual(
            model.meetingIntelligencePresentation(for: session),
            genuinePresentation
        )
        XCTAssertEqual(model.meetingIntelligencePresentation(for: noncanonical), .empty)
    }

    func testSymlinkWorkspaceAdmitsCanonicalTranscriptPublicationForMeetingIntelligence() async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let physicalWorkspace = root.appendingPathComponent("physical-workspace", isDirectory: true)
        let linkedWorkspace = root.appendingPathComponent("linked-workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: physicalWorkspace, withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedWorkspace, withDestinationURL: physicalWorkspace
        )
        let session = try makeDiskSession(in: physicalWorkspace, name: "canonical")
        try "canonical transcript".write(
            to: session.folderURL.appendingPathComponent("transcript.txt"),
            atomically: true, encoding: .utf8
        )

        let feature = makeFeature(session: session)
        let availabilityReached = expectation(
            description: "canonical transcript in a symlinked workspace reaches availability"
        )
        let availability = CountingAvailability(onAvailability: {
            availabilityReached.fulfill()
        })
        var coordinator: MeetingIntelligenceJobCoordinator!
        let model = AppModel(
            providerRepository: ImportTestProvider(),
            performStartupWork: false, initialOutputFolder: linkedWorkspace,
            libraryFeature: feature,
            meetingIntelligenceFeatureFactory: { repository, sourceID, gate in
                let artifacts = MeetingIntelligenceArtifactStore(mutationGate: gate)
                coordinator = MeetingIntelligenceJobCoordinator(
                    providerRepository: repository,
                    expectedPublicationSourceID: sourceID,
                    mutationGate: gate,
                    transcriptReader: CountingTranscriptReader(),
                    availabilityChecker: availability,
                    generator: NeverGeneratingMeetingIntelligence(),
                    publisher: MeetingIntelligencePublisher(
                        mutationGate: gate, artifactStore: artifacts
                    ),
                    artifactStore: artifacts,
                    stateStore: MeetingIntelligenceStateStore(mutationGate: gate)
                )
                return MeetingIntelligenceFeatureModel(coordinator: coordinator)
            }
        )
        model.seedLibrarySessionsForTesting([session])
        defer { model.shutdown() }

        let transcript = try SecureTranscriptDocumentReader().readCanonical(
            in: session.folderURL, allowLegacy: false
        )
        let publication = TranscriptPublished(
            session: session,
            canonicalURL: transcript.url,
            revision: transcript.revision,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
            identity: .init(
                coordinatorInstanceID: model.transcriptionFeature.publicationSourceID,
                generation: 1, attemptID: UUID()
            ),
            workspaceFence: .initial
        )

        model.transcriptionFeature.onSuccessfulPublication?(publication)

        await fulfillment(of: [availabilityReached], timeout: 1)
        await coordinator.waitUntilIdleForTesting(sessionID: session.id)
        XCTAssertEqual(
            model.meetingIntelligencePresentation(for: session).unavailableReason,
            .connectionFailed
        )
    }

    func testWorkspaceChangeAfterAwaitDoesNotOverwriteStatusForImportSaveAndTrash() async throws {
        let root = try makeTemporaryFolder()
        let replacement = try makeTemporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: replacement)
        }
        let source = root.appendingPathComponent("source.m4a")
        try Data([1]).write(to: source)

        let importAdmission = expectation(description: "import reaches its asynchronous boundary")
        let importBlocker = AsyncActionBlocker(onAdmission: { importAdmission.fulfill() })
        defer { importBlocker.release() }
        let imported = makeSession(in: root, name: "imported")
        let importFeature = LibraryFeatureModel(
            sessionLoader: { _ in [] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in true }, audioImporter: { _, _ in
                importBlocker.block()
                return imported
            }
        )
        let importModel = AppModel(
            performStartupWork: false, initialOutputFolder: root,
            libraryFeature: importFeature
        )
        importModel.seedLibrarySessionsForTesting([])
        let importTask = Task { await importModel.importAudioForTranscription(source) }
        await fulfillment(of: [importAdmission], timeout: 1)
        importModel.statusMessage = "new workspace import status"
        importModel.setOutputFolder(replacement)
        importBlocker.release()
        guard case .failure = await importTask.value else {
            return XCTFail("stale import must retain its typed failure")
        }
        XCTAssertEqual(importModel.statusMessage, "new workspace import status")

        let transcriptAdmission = expectation(description: "transcript save reaches its asynchronous boundary")
        let transcriptBlocker = AsyncActionBlocker(onAdmission: { transcriptAdmission.fulfill() })
        defer { transcriptBlocker.release() }
        let transcriptSession = try makeDiskSession(in: root, name: "transcript")
        let transcriptFeature = LibraryFeatureModel(
            sessionLoader: { _ in [transcriptSession] }, sessionReloader: { $0 },
            searchDocumentLoader: { session in
                transcriptBlocker.block()
                return session.searchDocument
            }, recovery: { _ in }, trashHandler: { _ in true }
        )
        let transcriptModel = AppModel(
            performStartupWork: false, initialOutputFolder: root,
            libraryFeature: transcriptFeature
        )
        transcriptModel.seedLibrarySessionsForTesting([transcriptSession])
        let transcriptTask = Task {
            await transcriptModel.saveTranscript("text", for: transcriptSession)
        }
        await fulfillment(of: [transcriptAdmission], timeout: 1)
        transcriptModel.statusMessage = "new workspace transcript status"
        transcriptModel.setOutputFolder(replacement)
        transcriptBlocker.release()
        let transcriptOutcome = await transcriptTask.value
        XCTAssertFalse(transcriptOutcome.savedArtifacts.contains(.transcript))
        XCTAssertEqual(transcriptModel.statusMessage, "new workspace transcript status")

        let metadataAdmission = expectation(description: "metadata save reaches its asynchronous boundary")
        let metadataBlocker = AsyncActionBlocker(onAdmission: { metadataAdmission.fulfill() })
        defer { metadataBlocker.release() }
        let metadataSession = try makeDiskSession(in: root, name: "metadata")
        let metadataFeature = LibraryFeatureModel(
            sessionLoader: { _ in [metadataSession] }, sessionReloader: { _ in
                metadataBlocker.block()
                return metadataSession
            }, searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in true }
        )
        let metadataModel = AppModel(
            performStartupWork: false, initialOutputFolder: root,
            libraryFeature: metadataFeature
        )
        metadataModel.seedLibrarySessionsForTesting([metadataSession])
        let metadataTask = Task {
            await metadataModel.saveMetadata(
                title: "changed", tags: "", isFavorite: false,
                for: metadataSession
            )
        }
        await fulfillment(of: [metadataAdmission], timeout: 1)
        metadataModel.statusMessage = "new workspace metadata status"
        metadataModel.setOutputFolder(replacement)
        metadataBlocker.release()
        let metadataOutcome = await metadataTask.value
        XCTAssertFalse(metadataOutcome.savedArtifacts.contains(.metadata))
        XCTAssertEqual(metadataModel.statusMessage, "new workspace metadata status")

        let trashAdmission = expectation(description: "trash reaches its asynchronous boundary")
        let trashBlocker = AsyncActionBlocker(onAdmission: { trashAdmission.fulfill() })
        defer { trashBlocker.release() }
        let trashSession = makeSession(in: root, name: "trash")
        let trashFeature = LibraryFeatureModel(
            sessionLoader: { _ in [trashSession] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in trashBlocker.block(); return true }
        )
        let trashModel = AppModel(
            performStartupWork: false, initialOutputFolder: root,
            libraryFeature: trashFeature
        )
        trashModel.seedLibrarySessionsForTesting([trashSession])
        let trashTask = Task { await trashModel.moveSessionToTrash(trashSession) }
        await fulfillment(of: [trashAdmission], timeout: 1)
        trashModel.statusMessage = "new workspace trash status"
        trashModel.setOutputFolder(replacement)
        trashBlocker.release()
        await trashTask.value
        XCTAssertEqual(trashModel.statusMessage, "new workspace trash status")
    }

    private func makeTemporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFeature(session: RecordingSession) -> LibraryFeatureModel {
        LibraryFeatureModel(
            sessionLoader: { _ in [session] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in true }
        )
    }

    private func makeSession(in root: URL, name: String) -> RecordingSession {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        return .init(
            id: folder.standardizedFileURL, folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .now, duration: 0, fileSize: 0, metadata: .init()
        )
    }

    private func makeDiskSession(in root: URL, name: String) throws -> RecordingSession {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("recording.m4a"))
        try RecordingSessionMetadataStore.save(.init(), in: folder)
        return RecordingSessionStore.session(
            for: folder, recordingURL: folder.appendingPathComponent("recording.m4a")
        )
    }

    private func libraryIdentity(
        for session: RecordingSession,
        feature: LibraryFeatureModel,
        transcriptRevision: TranscriptDocumentRevision? = nil
    ) -> LibraryMutationIdentity {
        .init(
            librarySourceID: feature.librarySourceID,
            mutationID: UUID(), sessionID: session.id,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
            transcriptRevision: transcriptRevision, workspaceFence: .initial
        )
    }

}

private final class AsyncActionBlocker: @unchecked Sendable {
    private let condition = NSCondition()
    private let onAdmission: () -> Void
    private var blocked = false
    private var didNotifyAdmission = false
    private var released = false

    init(onAdmission: @escaping () -> Void = {}) {
        self.onAdmission = onAdmission
    }

    func block() {
        let shouldNotify: Bool
        condition.lock()
        blocked = true
        shouldNotify = !didNotifyAdmission
        didNotifyAdmission = true
        condition.broadcast()
        condition.unlock()
        if shouldNotify { onAdmission() }

        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }
    var isBlocked: Bool {
        condition.lock(); defer { condition.unlock() }
        return blocked
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

private final class CountingTranscriptReader: TranscriptDocumentReading, @unchecked Sendable {
    private let lock = NSLock()
    private let reader = SecureTranscriptDocumentReader()
    private var storage = 0
    var count: Int { lock.withLock { storage } }

    func readCanonical(
        in sessionFolder: URL,
        allowLegacy: Bool
    ) throws -> TranscriptDocumentSnapshot {
        lock.withLock { storage += 1 }
        return try reader.readCanonical(
            in: sessionFolder, allowLegacy: allowLegacy
        )
    }
}

private final class CountingAvailability: MeetingIntelligenceAvailabilityChecking,
    @unchecked Sendable {
    private let lock = NSLock()
    private let onAvailability: () -> Void
    private var storage = 0
    var count: Int { lock.withLock { storage } }

    init(onAvailability: @escaping () -> Void = {}) {
        self.onAvailability = onAvailability
    }

    func availability(
        for snapshot: OpenAICompatibleProviderSnapshot
    ) async -> MeetingIntelligenceAvailability {
        lock.withLock { storage += 1 }
        onAvailability()
        return .unconfirmed(.connectionFailed)
    }
}

private struct NeverGeneratingMeetingIntelligence: MeetingIntelligenceGenerating {
    func generate(
        transcript: TranscriptDocumentSnapshot,
        snapshot: OpenAICompatibleProviderSnapshot,
        onProgress: @escaping @Sendable (MeetingIntelligenceProgress) -> Void
    ) async throws -> MeetingIntelligenceGeneratedContent {
        throw ImportTestError.failed
    }
}

private enum ImportTestError: Error { case failed }

private final class ImportCountingPreparer: TranscriptionAudioPreparing, @unchecked Sendable {
    private let lock = NSLock()
    private let onPrepare: () -> Void
    private var count = 0
    var requestCount: Int { lock.withLock { count } }
    init(onPrepare: @escaping () -> Void = {}) {
        self.onPrepare = onPrepare
    }
    func prepare(for session: RecordingSession) async throws -> PreparedTranscriptionAudio {
        lock.withLock { count += 1 }
        onPrepare()
        throw ImportTestError.failed
    }
    func cleanup(_ prepared: PreparedTranscriptionAudio) {}
}

private final class ImportTestProvider: OpenAICompatibleProviderManaging {
    private let profile: OpenAICompatibleProviderProfile
    init() {
        profile = try! OpenAICompatibleProviderProfile.validated(
            baseURLText: "https://api.example.com/v1", asrModel: "asr",
            llmModel: "llm", language: "en", prompt: ""
        )
    }
    func loadProfile() throws -> OpenAICompatibleProviderProfile? { profile }
    func loadProfile(for kind: AIProviderKind) throws -> OpenAICompatibleProviderProfile? {
        kind == .openAICompatible ? profile : nil
    }
    func activeProviderKind() throws -> AIProviderKind { .openAICompatible }
    func setActiveProviderKind(_ kind: AIProviderKind) throws {}
    func save(profile: OpenAICompatibleProviderProfile, replacementAPIKey: String?) throws {}
    func snapshot() throws -> OpenAICompatibleProviderSnapshot {
        try .validated(profile: profile, apiKey: "test")
    }
    func snapshot(overriding profile: OpenAICompatibleProviderProfile) throws -> OpenAICompatibleProviderSnapshot {
        try .validated(profile: profile, apiKey: "test")
    }
    func hasAPIKey() throws -> Bool { true }
    func hasAPIKey(for kind: AIProviderKind) throws -> Bool { kind == .openAICompatible }
    func removeAPIKey() throws {}
    func removeAPIKey(for kind: AIProviderKind) throws {}
    func migrateLegacyIfNeeded(settingsURL: URL) throws -> LegacyProviderMigrationOutcome { .notFound }
}
