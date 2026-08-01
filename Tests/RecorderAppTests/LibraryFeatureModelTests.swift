import Combine
import XCTest
@testable import RecorderApp

@MainActor
final class LibraryFeatureModelTests: XCTestCase {
    func testEditorSaveDispositionKeepsDraftOpenForFailureOrOtherArtifact() {
        let expectedSessionID = LibraryFeatureFixture.session(named: "editor").id
        let otherSessionID = LibraryFeatureFixture.session(named: "other-editor").id
        XCTAssertEqual(
            LibraryEditorSaveDisposition.disposition(
                for: .transcript,
                expectedSessionID: expectedSessionID,
                outcome: .failed(sessionID: expectedSessionID, .transcript, "failed")
            ),
            .keepOpen
        )
        XCTAssertEqual(
            LibraryEditorSaveDisposition.disposition(
                for: .transcript,
                expectedSessionID: expectedSessionID,
                outcome: .saved(sessionID: expectedSessionID, .metadata)
            ),
            .keepOpen
        )
        XCTAssertEqual(
            LibraryEditorSaveDisposition.disposition(
                for: .metadata,
                expectedSessionID: otherSessionID,
                outcome: .saved(sessionID: expectedSessionID, .metadata)
            ),
            .keepOpen
        )
        XCTAssertEqual(
            LibraryEditorSaveDisposition.disposition(
                for: .metadata,
                expectedSessionID: expectedSessionID,
                outcome: .saved(sessionID: expectedSessionID, .metadata)
            ),
            .dismiss
        )
    }
    func testRefreshPublishesCanonicalSessionsFromTheLoadingQueue() async {
        let session = LibraryFeatureFixture.session(named: "queued")
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [session] },
            sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument },
            recovery: { _ in },
            trashHandler: { _ in true }
        )

        let published = expectation(description: "canonical session published")
        feature.onSessionsLoaded = { snapshot in
            guard snapshot.sessions == [session] else { return }
            published.fulfill()
        }
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [published], timeout: 1)
    }

    func testLatestRefreshGenerationWins() async {
        let first = LibraryFeatureFixture.session(named: "first")
        let latest = LibraryFeatureFixture.session(named: "latest")
        let blocker = RefreshBlocker()
        let feature = LibraryFeatureModel(
            sessionLoader: { folder in
                if folder.lastPathComponent == "first" {
                    blocker.blockFirstLoad()
                    return [first]
                }
                return [latest]
            },
            sessionReloader: { $0 }, searchDocumentLoader: { $0.searchDocument },
            recovery: { _ in }, trashHandler: { _ in true }
        )
        defer { blocker.release() }
        let latestPublished = expectation(description: "latest refresh")
        let staleFirstPublished = expectation(description: "stale first refresh rejected")
        staleFirstPublished.isInverted = true
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [latest] {
                latestPublished.fulfill()
            } else if snapshot.sessions == [first] {
                staleFirstPublished.fulfill()
            }
        }
        feature.refresh(workspace: URL(fileURLWithPath: "/tmp/first"), fence: .initial)
        XCTAssertTrue(blocker.waitUntilBlocked())
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        blocker.release()
        await fulfillment(of: [latestPublished], timeout: 1)
        await fulfillment(of: [staleFirstPublished], timeout: 0.1)
        XCTAssertEqual(feature.sessions, [latest])
    }

    func testSameWorkspaceRefreshKeepsNewerSearchDocumentWhenStaleIndexingCompletes() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "refresh-search-order")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let initial = LibraryFeatureFixture.diskSession(folder: folder)
        let newer = initial.replacingSearchDocument(
            .init(metadataText: "newer metadata", transcriptText: "newer transcript")
        )
        let staleLoader = SearchLoadBlocker { _ in
            .init(metadataText: "stale metadata", transcriptText: "stale transcript")
        }
        defer { staleLoader.releaseFirst() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [newer] }, sessionReloader: { $0 },
            searchDocumentLoader: { staleLoader.load($0) }, recovery: { _ in }, trashHandler: { _ in true }
        )
        feature.seedCanonicalSessionsForTesting(
            [initial], workspace: folder.deletingLastPathComponent(), fence: .initial
        )

        let edited = expectation(description: "durable transcript event publishes exactly once")
        var editEvents = 0
        feature.onTranscriptEdited = { _ in editEvents += 1; edited.fulfill() }

        let staleIndexStarted = expectation(description: "stale search indexing started")
        staleLoader.onFirstBlocked = { staleIndexStarted.fulfill() }
        let save = Task {
            await feature.saveTranscript("persisted transcript", for: initial, fence: .initial)
        }
        await fulfillment(of: [staleIndexStarted], timeout: 1)

        let refreshRetainsDurableTicket = expectation(description: "refresh retains durable transcript ticket")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [initial] { refreshRetainsDurableTicket.fulfill() }
        }
        feature.refresh(workspace: folder.deletingLastPathComponent(), fence: .initial)
        await fulfillment(of: [refreshRetainsDurableTicket], timeout: 1)

        let newerRefreshPublished = expectation(description: "post-ticket refresh publishes newer projection")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [newer] { newerRefreshPublished.fulfill() }
        }
        staleLoader.releaseFirst()
        let outcome = await save.value
        XCTAssertEqual(outcome, .saved(sessionID: initial.id, .transcript))
        await fulfillment(of: [edited], timeout: 1)
        XCTAssertEqual(editEvents, 1)
        await fulfillment(of: [newerRefreshPublished], timeout: 1)
        XCTAssertEqual(feature.session(withID: initial.id)?.searchDocument, newer.searchDocument)
    }

    func testDurableTicketFollowUpRefreshPublishesDistinctExternalProjectionAfterTypedEvent() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "durable-ticket-follow-up")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let current = LibraryFeatureFixture.diskSession(folder: folder)
        let competing = RecordingSession(
            id: current.id,
            folderURL: current.folderURL,
            recordingURL: current.recordingURL,
            createdAt: current.createdAt,
            duration: current.duration,
            fileSize: current.fileSize,
            metadata: .init(title: "Competing during ticket")
        )
        let external = RecordingSession(
            id: current.id,
            folderURL: current.folderURL,
            recordingURL: current.recordingURL,
            createdAt: current.createdAt,
            duration: current.duration,
            fileSize: current.fileSize,
            metadata: .init(title: "External after ticket")
        )
        let loads = RefreshLoadSequencer(results: [[competing], [external]], blockOnCall: 0)
        let indexing = SearchLoadBlocker { candidate in
            .init(
                metadataText: candidate.displayName,
                transcriptText: (try? TranscriptDocumentStore.read(in: candidate.folderURL)) ?? ""
            )
        }
        defer { indexing.releaseFirst() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in loads.load() },
            sessionReloader: { $0 },
            searchDocumentLoader: { indexing.load($0) },
            recovery: { _ in },
            trashHandler: { _ in true }
        )
        let workspace = folder.deletingLastPathComponent()
        feature.seedCanonicalSessionsForTesting([current], workspace: workspace, fence: .initial)

        let indexingStarted = expectation(description: "durable ticket indexing started")
        indexing.onFirstBlocked = { indexingStarted.fulfill() }
        let typedEvent = expectation(description: "typed transcript event is emitted before follow-up refresh")
        feature.onTranscriptEdited = { _ in typedEvent.fulfill() }
        let competingRefreshObserved = expectation(description: "competing refresh observes and retains durable ticket")
        let externalRefreshPublished = expectation(description: "post-ticket follow-up refresh publishes distinct external projection")
        feature.onSessionsLoaded = { snapshot in
            switch snapshot.sessions.first?.displayName {
            case current.displayName:
                competingRefreshObserved.fulfill()
            case external.displayName:
                externalRefreshPublished.fulfill()
            default:
                break
            }
        }

        let save = Task {
            await feature.saveTranscript("durable transcript", for: current, fence: .initial)
        }
        await fulfillment(of: [indexingStarted], timeout: 1)

        feature.refresh(workspace: workspace, fence: .initial)
        await fulfillment(of: [competingRefreshObserved], timeout: 1)

        indexing.releaseFirst()
        let outcome = await save.value
        XCTAssertEqual(outcome, .saved(sessionID: current.id, .transcript))
        await fulfillment(of: [typedEvent], timeout: 1)
        await fulfillment(of: [externalRefreshPublished], timeout: 1)
        XCTAssertEqual(feature.session(withID: current.id)?.displayName, external.displayName)
    }

    func testSameWorkspaceRefreshKeepsNewerMetadataAndSearchDocumentWhenStaleReloadCompletes() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "refresh-reload-order")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let initial = LibraryFeatureFixture.diskSession(folder: folder)
        let stale = RecordingSession(
            id: initial.id, folderURL: initial.folderURL, recordingURL: initial.recordingURL,
            createdAt: initial.createdAt, duration: initial.duration, fileSize: initial.fileSize,
            metadata: .init(title: "stale")
        )
        let newer = RecordingSession(
            id: initial.id, folderURL: initial.folderURL, recordingURL: initial.recordingURL,
            createdAt: initial.createdAt, duration: initial.duration, fileSize: initial.fileSize,
            metadata: .init(title: "newer")
        ).replacingSearchDocument(.init(metadataText: "newer metadata", transcriptText: "newer transcript"))
        let reloader = ReloadSequencer(first: stale, latest: stale)
        defer { reloader.releaseFirst() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [newer] }, sessionReloader: { reloader.load($0) },
            searchDocumentLoader: {
                .init(metadataText: $0.displayName, transcriptText: "stale transcript")
            },
            recovery: { _ in }, trashHandler: { _ in true }
        )
        feature.seedCanonicalSessionsForTesting(
            [initial], workspace: folder.deletingLastPathComponent(), fence: .initial
        )

        let metadataSaved = expectation(description: "durable metadata event publishes exactly once")
        var metadataEvents = 0
        feature.onMetadataSaved = { _ in metadataEvents += 1; metadataSaved.fulfill() }

        let staleReloadStarted = expectation(description: "stale reload started")
        reloader.onFirstBlocked = { staleReloadStarted.fulfill() }
        let save = Task {
            await feature.saveMetadata(
                titleEdit: .manual("persisted"), tags: "", isFavorite: false,
                for: initial, fence: .initial
            )
        }
        await fulfillment(of: [staleReloadStarted], timeout: 1)

        let refreshRetainsDurableTicket = expectation(description: "refresh retains durable metadata ticket")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [initial] { refreshRetainsDurableTicket.fulfill() }
        }
        feature.refresh(workspace: folder.deletingLastPathComponent(), fence: .initial)
        await fulfillment(of: [refreshRetainsDurableTicket], timeout: 1)

        let newerRefreshPublished = expectation(description: "post-ticket refresh publishes newer projection")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [newer] { newerRefreshPublished.fulfill() }
        }
        reloader.releaseFirst()
        let outcome = await save.value
        XCTAssertEqual(outcome, .saved(sessionID: initial.id, .metadata))
        await fulfillment(of: [metadataSaved], timeout: 1)
        XCTAssertEqual(metadataEvents, 1)
        await fulfillment(of: [newerRefreshPublished], timeout: 1)
        XCTAssertEqual(feature.session(withID: initial.id)?.displayName, "newer")
        XCTAssertEqual(feature.session(withID: initial.id)?.searchDocument, newer.searchDocument)
    }

    func testRecoveryRunsOncePerWorkspaceFence() async {
        let count = LockedCounter()
        let recovered = expectation(description: "recovery runs once")
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in
                count.increment()
                recovered.fulfill()
            },
            trashHandler: { _ in true }
        )
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [recovered], timeout: 1)
        XCTAssertEqual(count.value, 1)
    }

    func testRecoveryRunsAgainOnlyWhenTheWorkspaceFenceAdvances() async {
        let count = LockedCounter()
        let twice = expectation(description: "recovery runs for the advanced workspace revision")
        twice.expectedFulfillmentCount = 2
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in
                count.increment()
                twice.fulfill()
            }, trashHandler: { _ in true }
        )

        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        feature.clearForWorkspaceChange()
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial.advanced())
        await fulfillment(of: [twice], timeout: 1)
        XCTAssertEqual(count.value, 2)
    }

    func testWorkspaceChangeClearsOldProjectionBeforeOneRefresh() {
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true }
        )
        feature.seedCanonicalSessionsForTesting(
            [LibraryFeatureFixture.session(named: "old")],
            workspace: LibraryFeatureFixture.workspace,
            fence: .initial
        )
        feature.clearForWorkspaceChange()
        XCTAssertTrue(feature.sessions.isEmpty)
    }

    func testOldWorkspaceRefreshCompletionIsRejectedAfterNewWorkspacePublishes() async {
        let old = URL(fileURLWithPath: "/tmp/old-library")
        let oldSession = RecordingSession(
            id: old.appendingPathComponent("meeting"), folderURL: old.appendingPathComponent("meeting"),
            recordingURL: old.appendingPathComponent("meeting/recording.m4a"), createdAt: .now,
            duration: 1, fileSize: 1, metadata: .init()
        )
        let blocker = RefreshBlocker()
        defer { blocker.release() }
        let feature = LibraryFeatureModel(
            sessionLoader: { folder in
                if folder.standardizedFileURL == old.standardizedFileURL {
                    blocker.blockFirstLoad()
                    return [oldSession]
                }
                return []
            }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true }
        )
        let newWorkspacePublished = expectation(description: "enqueued new workspace publishes after old loader returns")
        let oldWorkspacePublished = expectation(description: "old refresh never republishes")
        oldWorkspacePublished.isInverted = true
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.isEmpty {
                newWorkspacePublished.fulfill()
            } else if snapshot.sessions.contains(where: { $0.id == oldSession.id }) {
                oldWorkspacePublished.fulfill()
            }
        }
        feature.refresh(workspace: old, fence: .initial)
        XCTAssertTrue(blocker.waitUntilBlocked())
        feature.clearForWorkspaceChange()
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial.advanced())
        blocker.release()
        await fulfillment(of: [newWorkspacePublished], timeout: 1)
        await fulfillment(of: [oldWorkspacePublished], timeout: 0.1)
        XCTAssertFalse(feature.sessions.contains { $0.id == oldSession.id })
    }

    func testOldWorkspaceSearchCompletionIsRejectedAfterNewWorkspacePublishes() async {
        let old = URL(fileURLWithPath: "/tmp/old-library-search")
        let oldSession = RecordingSession(
            id: old.appendingPathComponent("meeting"), folderURL: old.appendingPathComponent("meeting"),
            recordingURL: old.appendingPathComponent("meeting/recording.m4a"), createdAt: .now,
            duration: 1, fileSize: 1, metadata: .init(title: "old")
        )
        let blocker = SearchLoadBlocker()
        defer { blocker.releaseFirst() }
        let feature = LibraryFeatureModel(
            sessionLoader: { folder in folder.standardizedFileURL == old.standardizedFileURL ? [oldSession] : [] },
            sessionReloader: { $0 }, searchDocumentLoader: { input in blocker.load(input) },
            recovery: { _ in }, trashHandler: { _ in true }
        )
        feature.seedCanonicalSessionsForTesting([oldSession], workspace: old, fence: .initial)
        let newWorkspacePublished = expectation(description: "new workspace publishes before old search releases")
        let staleSearchCommit = expectation(description: "old search cannot republish")
        let oldSearchStarted = expectation(description: "old workspace search is in flight")
        let oldSearchReturned = expectation(description: "old workspace search returned")
        staleSearchCommit.isInverted = true
        blocker.onFirstBlocked = { oldSearchStarted.fulfill() }
        blocker.onFirstReturned = { oldSearchReturned.fulfill() }
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.isEmpty { newWorkspacePublished.fulfill() }
        }
        feature.onTranscriptPublicationCommitted = { _ in staleSearchCommit.fulfill() }

        feature.acceptTranscriptPublication(LibraryFeatureFixture.publication(for: oldSession, fence: .initial))
        await fulfillment(of: [oldSearchStarted], timeout: 1)
        feature.clearForWorkspaceChange()
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial.advanced())
        await fulfillment(of: [newWorkspacePublished], timeout: 1)
        blocker.releaseFirst()
        await fulfillment(of: [oldSearchReturned], timeout: 1)
        await fulfillment(of: [staleSearchCommit], timeout: 0.1)
        XCTAssertFalse(feature.sessions.contains { $0.id == oldSession.id })
    }

    func testSearchRebuildUsesCurrentCanonicalMetadataForAStaleInputSession() async {
        let session = LibraryFeatureFixture.session(named: "search")
        let current = RecordingSession(
            id: session.id, folderURL: session.folderURL, recordingURL: session.recordingURL,
            createdAt: session.createdAt, duration: session.duration, fileSize: session.fileSize,
            metadata: .init(title: "current")
        )
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [current] }, sessionReloader: { $0 },
            searchDocumentLoader: { input in .init(metadataText: input.displayName, transcriptText: "") },
            recovery: { _ in }, trashHandler: { _ in true }
        )
        let loaded = expectation(description: "current canonical session loaded")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [current] { loaded.fulfill() }
        }
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [loaded], timeout: 1)
        let committed = expectation(description: "stale input is rebuilt from current metadata")
        feature.onTranscriptPublicationCommitted = { _ in committed.fulfill() }
        feature.acceptTranscriptPublication(LibraryFeatureFixture.publication(for: session, fence: .initial))
        await fulfillment(of: [committed], timeout: 1)
        XCTAssertEqual(feature.sessions.first?.searchDocument.metadataText, "current")
    }

    func testMetadataSaveRequeuesCurrentMetadataAfterBlockedStaleSearch() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "requeue")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let oldMetadata = RecordingSessionMetadata(title: "old")
        try RecordingSessionMetadataStore.save(oldMetadata, in: folder)
        let old = LibraryFeatureFixture.diskSession(folder: folder)
        let current = RecordingSession(
            id: old.id, folderURL: old.folderURL, recordingURL: old.recordingURL,
            createdAt: old.createdAt, duration: old.duration, fileSize: old.fileSize,
            metadata: .init(title: "current")
        )
        let loader = SearchLoadBlocker()
        defer { loader.releaseFirst() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [old] }, sessionReloader: { _ in current },
            searchDocumentLoader: { input in loader.load(input) }, recovery: { _ in }, trashHandler: { _ in true }
        )
        let loaded = expectation(description: "old canonical session loaded")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [old] { loaded.fulfill() }
        }
        feature.refresh(workspace: folder.deletingLastPathComponent(), fence: .initial)
        await fulfillment(of: [loaded], timeout: 1)
        let metadataSaved = expectation(description: "current metadata is indexed")
        feature.onMetadataSaved = { saved in
            if saved.canonicalSession.displayName == "current" { metadataSaved.fulfill() }
        }
        let staleSearchStarted = expectation(description: "old metadata search is in flight")
        let currentSearchStarted = expectation(description: "current metadata search is queued")
        let staleSearchReturned = expectation(description: "old metadata search returned")
        loader.onFirstBlocked = { staleSearchStarted.fulfill() }
        loader.onSecondCall = { currentSearchStarted.fulfill() }
        loader.onFirstReturned = { staleSearchReturned.fulfill() }
        feature.acceptTranscriptPublication(LibraryFeatureFixture.publication(for: old, fence: .initial))
        await fulfillment(of: [staleSearchStarted], timeout: 1)
        let saveTask = Task {
            await feature.saveMetadata(
                titleEdit: .manual("current"), tags: "", isFavorite: false,
                for: old, fence: .initial
            )
        }
        await fulfillment(of: [currentSearchStarted], timeout: 1)
        XCTAssertEqual(loader.titles.prefix(2), ["old", "current"])
        loader.releaseFirst()
        await fulfillment(of: [staleSearchReturned, metadataSaved], timeout: 1)
        let saveOutcome = await saveTask.value
        XCTAssertEqual(saveOutcome, .saved(sessionID: old.id, .metadata))
        XCTAssertEqual(feature.sessions.first?.displayName, "current")
        XCTAssertEqual(feature.sessions.first?.searchDocument.metadataText, "current")
    }

    func testTranscriptPublicationEmitsCommittedOnlyAfterSearchRebuild() async {
        let session = LibraryFeatureFixture.session(named: "published")
        let event = LibraryFeatureFixture.publication(for: session, fence: .initial)
        let feature = LibraryFeatureModel(sessionLoader: { _ in [session] }, sessionReloader: { $0 }, searchDocumentLoader: { _ in .init(metadataText: "indexed", transcriptText: "") }, recovery: { _ in }, trashHandler: { _ in true })
        let loaded = expectation(description: "canonical session loaded")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [session] { loaded.fulfill() }
        }
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [loaded], timeout: 1)
        let committed = expectation(description: "committed")
        feature.onTranscriptPublicationCommitted = { _ in
            XCTAssertNotEqual(feature.sessions.first?.searchDocument, .empty)
            committed.fulfill()
        }
        feature.acceptTranscriptPublication(event)
        await fulfillment(of: [committed], timeout: 1)
    }

    func testRefreshReconcilesDurableTranscriptPublicationWhoseIndexingIsInFlight() async {
        let session = LibraryFeatureFixture.session(named: "publication-refresh-reconcile")
        let refreshed = session.replacingSearchDocument(
            .init(metadataText: "refreshed", transcriptText: "new transcript")
        )
        let blocker = SearchLoadBlocker {
            .init(metadataText: $0.displayName, transcriptText: "indexed transcript")
        }
        defer { blocker.releaseFirst() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [refreshed] },
            sessionReloader: { $0 },
            searchDocumentLoader: { blocker.load($0) },
            recovery: { _ in },
            trashHandler: { _ in true }
        )
        feature.seedCanonicalSessionsForTesting([session], workspace: LibraryFeatureFixture.workspace, fence: .initial)
        let indexingStarted = expectation(description: "publication indexing started")
        blocker.onFirstBlocked = { indexingStarted.fulfill() }
        let refreshReconciled = expectation(description: "refresh retains current transcript projection while durable indexing completes")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [session] { refreshReconciled.fulfill() }
        }
        let committed = expectation(description: "exactly one transcript publication committed")
        var commits = 0
        feature.onTranscriptPublicationCommitted = { _ in commits += 1; committed.fulfill() }

        feature.acceptTranscriptPublication(LibraryFeatureFixture.publication(for: session, fence: .initial))
        await fulfillment(of: [indexingStarted], timeout: 1)
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [refreshReconciled], timeout: 1)
        blocker.releaseFirst()

        await fulfillment(of: [committed], timeout: 1)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(feature.session(withID: session.id)?.searchDocument.transcriptText, "indexed transcript")
    }

    func testTranscriptFailureEmitsNoEditedEventAndReturnsFailure() async {
        let folder = try! LibraryFeatureFixture.makeDiskSession(named: "failure")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let session = LibraryFeatureFixture.diskSession(folder: folder)
        let feature = LibraryFeatureModel(sessionLoader: { _ in [session] }, sessionReloader: { $0 }, searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true })
        feature.refresh(workspace: folder.deletingLastPathComponent(), fence: .initial)
        var eventCount = 0
        feature.onTranscriptEdited = { _ in eventCount += 1 }
        feature.clearForWorkspaceChange()
        feature.refresh(workspace: URL(fileURLWithPath: "/tmp/new-workspace"), fence: .initial.advanced())
        let result = await feature.saveTranscript("text", for: session, fence: .initial)
        XCTAssertEqual(result, .failed(sessionID: session.id, .transcript, "The recording workspace changed before the transcript could be saved."))
        XCTAssertEqual(eventCount, 0)
    }

    func testTranscriptEditPersistsAndReindexesBeforeEmittingEdited() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "edited")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let session = LibraryFeatureFixture.diskSession(folder: folder)
        let feature = LibraryFeatureModel(sessionLoader: { _ in [session] }, sessionReloader: { $0 }, searchDocumentLoader: { input in .init(metadataText: input.displayName, transcriptText: (try? TranscriptDocumentStore.read(in: input.folderURL)) ?? "") }, recovery: { _ in }, trashHandler: { _ in true })
        let loaded = expectation(description: "editable session loaded")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [session] { loaded.fulfill() }
        }
        feature.refresh(workspace: folder.deletingLastPathComponent(), fence: .initial)
        await fulfillment(of: [loaded], timeout: 1)
        let changed = expectation(description: "edited after index")
        feature.onTranscriptEdited = { _ in
            XCTAssertTrue(feature.sessions.first?.searchDocument.transcriptText.contains("searchable") == true)
            changed.fulfill()
        }
        let outcome = await feature.saveTranscript("searchable", for: session, fence: .initial)
        XCTAssertEqual(outcome, .saved(sessionID: session.id, .transcript))
        await fulfillment(of: [changed], timeout: 1)
    }

    func testMetadataSaveReloadsCanonicalTitleTagsFavoriteAndSearchDocument() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "metadata")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let session = LibraryFeatureFixture.diskSession(folder: folder)
        let feature = LibraryFeatureFixture.diskFeature(session: session)
        let loaded = expectation(description: "metadata session loaded")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [session] { loaded.fulfill() }
        }
        feature.refresh(workspace: folder.deletingLastPathComponent(), fence: .initial)
        await fulfillment(of: [loaded], timeout: 1)
        let outcome = await feature.saveMetadata(titleEdit: .manual("Renamed"), tags: "one,two", isFavorite: true, for: session, fence: .initial)
        XCTAssertEqual(outcome, .saved(sessionID: session.id, .metadata))
        XCTAssertEqual(feature.sessions.first?.displayName, "Renamed")
        XCTAssertEqual(feature.sessions.first?.tags, ["one", "two"])
        XCTAssertEqual(feature.sessions.first?.isFavorite, true)
        XCTAssertTrue(feature.sessions.first?.searchDocument.metadataText.contains("Renamed") == true)
    }

    func testMetadataSavePreservesExistingTitleOriginWhenTitleIsUnchanged() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "origin")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var metadata = RecordingSessionMetadata(title: "Generated")
        metadata.titleOrigin = .meetingIntelligence
        try RecordingSessionMetadataStore.save(metadata, in: folder)
        let session = LibraryFeatureFixture.diskSession(folder: folder)
        let feature = LibraryFeatureFixture.diskFeature(session: session)
        let loaded = expectation(description: "origin session loaded")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [session] { loaded.fulfill() }
        }
        feature.refresh(workspace: folder.deletingLastPathComponent(), fence: .initial)
        await fulfillment(of: [loaded], timeout: 1)
        let outcome = await feature.saveMetadata(titleEdit: .unchanged, tags: "tag", isFavorite: false, for: session, fence: .initial)
        XCTAssertEqual(outcome, .saved(sessionID: session.id, .metadata))
        XCTAssertEqual(RecordingSessionMetadataStore.load(in: folder).titleOrigin, .meetingIntelligence)
    }

    func testLatestMeetingIntelligenceTargetedReloadWins() async {
        let session = LibraryFeatureFixture.session(named: "mi")
        let latest = RecordingSession(id: session.id, folderURL: session.folderURL, recordingURL: session.recordingURL, createdAt: session.createdAt, duration: session.duration, fileSize: session.fileSize, metadata: .init(title: "Latest"))
        let reloader = ReloadSequencer(first: session, latest: latest)
        let latestApplied = expectation(description: "latest targeted reload applied")
        let staleFirstApplied = expectation(description: "stale targeted reload rejected")
        staleFirstApplied.isInverted = true
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [session] }, sessionReloader: { reloader.load($0) },
            searchDocumentLoader: { input in
                if input == latest {
                    latestApplied.fulfill()
                } else if input == session {
                    staleFirstApplied.fulfill()
                }
                return input.searchDocument
            }, recovery: { _ in }, trashHandler: { _ in true }
        )
        let initiallyLoaded = expectation(description: "initial canonical session loaded")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [session] { initiallyLoaded.fulfill() }
        }
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [initiallyLoaded], timeout: 1)
        let firstReloadStarted = expectation(description: "first targeted reload started")
        let secondReloadStarted = expectation(description: "second targeted reload started")
        let firstReloadReturned = expectation(description: "first targeted reload returned")
        reloader.onFirstBlocked = { firstReloadStarted.fulfill() }
        reloader.onSecondCall = { secondReloadStarted.fulfill() }
        reloader.onFirstReturned = { firstReloadReturned.fulfill() }
        feature.refreshAfterMeetingIntelligence(session, fence: .initial)
        await fulfillment(of: [firstReloadStarted], timeout: 1)
        feature.refreshAfterMeetingIntelligence(session, fence: .initial)
        await fulfillment(of: [secondReloadStarted, latestApplied], timeout: 1)
        reloader.releaseFirst()
        await fulfillment(of: [firstReloadReturned, staleFirstApplied], timeout: 1)
        XCTAssertEqual(feature.sessions.first?.displayName, "Latest")
    }

    func testOldWorkspaceMeetingIntelligencePublicationIsIgnored() async {
        let old = LibraryFeatureFixture.session(named: "mi-old")
        let feature = LibraryFeatureModel(sessionLoader: { folder in folder.standardizedFileURL == LibraryFeatureFixture.workspace.standardizedFileURL ? [old] : [] }, sessionReloader: { $0 }, searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true })
        let oldLoaded = expectation(description: "old workspace loaded")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [old] { oldLoaded.fulfill() }
        }
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [oldLoaded], timeout: 1)
        let newWorkspaceLoaded = expectation(description: "new workspace loaded")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.isEmpty { newWorkspaceLoaded.fulfill() }
        }
        feature.clearForWorkspaceChange()
        feature.refresh(workspace: URL(fileURLWithPath: "/tmp/new-mi"), fence: .initial.advanced())
        feature.refreshAfterMeetingIntelligence(old, fence: .initial)
        await fulfillment(of: [newWorkspaceLoaded], timeout: 1)
        XCTAssertFalse(feature.sessions.contains { $0.id == old.id })
    }

    func testCurrentWorkspaceImportPublishesOneCanonicalReadyEvent() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("audio.m4a")
        try Data([1]).write(to: source)
        let document = RecordingLibrarySearchDocument(metadataText: "indexed", transcriptText: "")
        let feature = LibraryFeatureModel(sessionLoader: { _ in [] }, sessionReloader: { $0 }, searchDocumentLoader: { _ in document }, recovery: { _ in }, trashHandler: { _ in true })
        let initialRefreshSettled = expectation(description: "initial refresh settles")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.isEmpty { initialRefreshSettled.fulfill() }
        }
        feature.refresh(workspace: root, fence: .initial)
        await fulfillment(of: [initialRefreshSettled], timeout: 1)
        let ready = expectation(description: "import ready")
        var importedEvents: [ImportedAudioSessionReady] = []
        feature.onImportedAudioReady = { event in
            importedEvents.append(event)
            ready.fulfill()
        }
        guard case .success(let session) = await feature.importAudio(source, workspace: root, fence: .initial) else { return XCTFail("Expected import") }
        await fulfillment(of: [ready], timeout: 1)
        XCTAssertEqual(feature.sessions.first?.id, session.id)
        XCTAssertEqual(importedEvents.count, 1)
        XCTAssertEqual(importedEvents.first?.identity.librarySourceID, feature.librarySourceID)
        XCTAssertEqual(importedEvents.first?.identity.workspaceFence, .initial)
        XCTAssertEqual(importedEvents.first?.identity.normalizedSessionFolder,
                       RecordingLibraryURLIdentity.normalized(session.folderURL))
        XCTAssertEqual(importedEvents.first?.canonicalSession, feature.session(withID: session.id))
        XCTAssertEqual(importedEvents.first?.canonicalSession.searchDocument, document)
    }

    func testInFlightRefreshCannotOverwriteAnAlreadyPublishedImport() async throws {
        let root = try LibraryFeatureFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = RecordingSession(
            id: root.appendingPathComponent("imported", isDirectory: true),
            folderURL: root.appendingPathComponent("imported", isDirectory: true),
            recordingURL: root.appendingPathComponent("imported/recording.m4a"),
            createdAt: .now, duration: 1, fileSize: 1, metadata: .init(title: "Imported")
        )
        let loader = RefreshLoadSequencer(results: [[], [imported]], blockOnCall: 1)
        defer { loader.release() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in loader.load() }, sessionReloader: { $0 },
            searchDocumentLoader: { .init(metadataText: $0.displayName, transcriptText: "") },
            recovery: { _ in }, trashHandler: { _ in true },
            audioImporter: { _, _ in imported }
        )
        let importedReady = expectation(description: "import has its atomic canonical publication")
        let refreshed = expectation(description: "stale refresh is re-run without dropping import")
        feature.onImportedAudioReady = { _ in importedReady.fulfill() }
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.map(\.id)
                == [RecordingLibraryURLIdentity.normalized(imported.id)] {
                refreshed.fulfill()
            }
        }

        feature.refresh(workspace: root, fence: .initial)
        XCTAssertTrue(loader.waitUntilBlocked())
        let result = await feature.importAudio(root.appendingPathComponent("source.m4a"), workspace: root, fence: .initial)
        guard case .success = result else { return XCTFail("Expected import") }
        await fulfillment(of: [importedReady], timeout: 1)
        XCTAssertEqual(feature.session(withID: imported.id)?.displayName, "Imported")

        loader.release()
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertEqual(feature.sessions.map(\.id), [RecordingLibraryURLIdentity.normalized(imported.id)])
    }

    func testBlockedRefreshDoesNotResurrectTrashedSessionsOrTheirPersistedStates() async throws {
        let root = try LibraryFeatureFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let retainedFolder = root.appendingPathComponent("retained", isDirectory: true)
        let trashedFolder = root.appendingPathComponent("trashed", isDirectory: true)
        try FileManager.default.createDirectory(at: retainedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashedFolder, withIntermediateDirectories: true)
        let retained = RecordingSession(
            id: retainedFolder, folderURL: retainedFolder, recordingURL: retainedFolder.appendingPathComponent("recording.m4a"),
            createdAt: .now, duration: 1, fileSize: 1, metadata: .init()
        )
        let trashed = RecordingSession(
            id: trashedFolder, folderURL: trashedFolder, recordingURL: trashedFolder.appendingPathComponent("recording.m4a"),
            createdAt: .now, duration: 1, fileSize: 1, metadata: .init()
        )
        let state = TranscriptionState(phase: .queued, message: "queued", startedAt: .now, finishedAt: nil)
        try TranscriptionStateStore.save(state, in: retainedFolder)
        try TranscriptionStateStore.save(state, in: trashedFolder)
        let loader = RefreshLoadSequencer(results: [[retained, trashed]], blockOnCall: 2)
        defer { loader.release() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in loader.load() }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true }
        )
        let initiallyLoaded = expectation(description: "initial disk listing")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [retained, trashed] { initiallyLoaded.fulfill() }
        }
        feature.refresh(workspace: root, fence: .initial)
        await fulfillment(of: [initiallyLoaded], timeout: 1)

        let finalVisible = expectation(description: "only non-tombstoned sessions and states publish")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [retained], Set(snapshot.transcriptionStates.keys) == [retained.id] {
                finalVisible.fulfill()
            }
        }
        feature.refresh(workspace: root, fence: .initial)
        XCTAssertTrue(loader.waitUntilBlocked())
        guard case .success = await feature.moveToTrash(trashed, fence: .initial)
        else { return XCTFail("Expected trash") }
        loader.release()

        await fulfillment(of: [finalVisible], timeout: 1)
        XCTAssertEqual(feature.sessions, [retained])
    }

    func testImportRunsInjectedImporterOffMainActor() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("audio.m4a")
        try Data([1]).write(to: source)
        let didRunOffMain = LockedBoolean()
        let session = LibraryFeatureFixture.session(named: "import-thread")
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true },
            audioImporter: { _, _ in didRunOffMain.set(!Thread.isMainThread); return session }
        )
        feature.refresh(workspace: root, fence: .initial)
        _ = await feature.importAudio(source, workspace: root, fence: .initial)
        XCTAssertTrue(didRunOffMain.value)
    }

    func testTranscriptMutationGateRunsOffMainActor() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "mutation-thread")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let session = LibraryFeatureFixture.diskSession(folder: folder)
        let offMain = LockedBoolean()
        let gate = RecordingSessionMutationGate { offMain.set(!Thread.isMainThread) }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [session] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true },
            mutationGate: gate
        )
        feature.seedCanonicalSessionsForTesting(
            [session], workspace: folder.deletingLastPathComponent(), fence: .initial
        )
        _ = await feature.saveTranscript("text", for: session, fence: .initial)
        XCTAssertTrue(offMain.value)
    }

    func testTranscriptSaveReturnsWorkspaceFailureWhenShutdownDuringDurableWrite() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "transcript-shutdown-write")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let session = LibraryFeatureFixture.diskSession(folder: folder)
        let blocker = ImportBlocker()
        defer { blocker.release() }
        let gate = RecordingSessionMutationGate { blocker.wait() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [session] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true },
            mutationGate: gate
        )
        feature.seedCanonicalSessionsForTesting(
            [session], workspace: folder.deletingLastPathComponent(), fence: .initial
        )
        let writeStarted = expectation(description: "transcript durable write started")
        blocker.onBlocked = { writeStarted.fulfill() }

        let save = Task { await feature.saveTranscript("persisted", for: session, fence: .initial) }
        await fulfillment(of: [writeStarted], timeout: 1)
        feature.shutdown()
        blocker.release()

        let outcome = await save.value
        XCTAssertEqual(
            outcome,
            .failed(sessionID: session.id, .transcript, "The recording workspace changed before the transcript could be indexed.")
        )
    }

    func testMetadataSaveReturnsWorkspaceFailureWhenWorkspaceAdvancesDuringDurableWrite() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "metadata-workspace-write")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let session = LibraryFeatureFixture.diskSession(folder: folder)
        let blocker = ImportBlocker()
        defer { blocker.release() }
        let gate = RecordingSessionMutationGate { blocker.wait() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [session] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true },
            mutationGate: gate
        )
        let workspace = folder.deletingLastPathComponent()
        feature.seedCanonicalSessionsForTesting([session], workspace: workspace, fence: .initial)
        let writeStarted = expectation(description: "metadata durable write started")
        blocker.onBlocked = { writeStarted.fulfill() }

        let save = Task {
            await feature.saveMetadata(
                titleEdit: .manual("Updated"), tags: "tag", isFavorite: true,
                for: session, fence: .initial
            )
        }
        await fulfillment(of: [writeStarted], timeout: 1)
        feature.refresh(workspace: workspace, fence: .initial.advanced())
        blocker.release()

        let outcome = await save.value
        XCTAssertEqual(
            outcome,
            .failed(sessionID: session.id, .metadata, "The recording workspace changed before details could be indexed.")
        )
    }

    func testSameWorkspaceRefreshDoesNotCancelPersistedTranscriptIndexing() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "transcript-refresh-race")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let session = LibraryFeatureFixture.diskSession(folder: folder)
        let blocker = SearchLoadBlocker { candidate in
            .init(
                metadataText: candidate.displayName,
                transcriptText: (try? TranscriptDocumentStore.read(in: candidate.folderURL)) ?? ""
            )
        }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [RecordingSessionStore.session(for: folder, recordingURL: folder.appendingPathComponent("recording.m4a"))] },
            sessionReloader: { $0 },
            searchDocumentLoader: { blocker.load($0) }, recovery: { _ in }, trashHandler: { _ in true }
        )
        feature.seedCanonicalSessionsForTesting([session], workspace: folder.deletingLastPathComponent(), fence: .initial)
        let indexStarted = expectation(description: "transcript indexing started")
        blocker.onFirstBlocked = { indexStarted.fulfill() }
        let edited = expectation(description: "one transcript edited event")
        var editCount = 0
        feature.onTranscriptEdited = { _ in editCount += 1; edited.fulfill() }

        let save = Task { await feature.saveTranscript("persisted", for: session, fence: .initial) }
        await fulfillment(of: [indexStarted], timeout: 1)
        feature.refresh(workspace: folder.deletingLastPathComponent(), fence: .initial)
        blocker.releaseFirst()
        let outcome = await save.value
        XCTAssertEqual(outcome, .saved(sessionID: session.id, .transcript))
        await fulfillment(of: [edited], timeout: 1)
        XCTAssertEqual(editCount, 1)
        XCTAssertEqual(feature.session(withID: session.id)?.searchDocument.transcriptText, "persisted")
    }

    func testSameWorkspaceRefreshDoesNotCancelPersistedMetadataReloadAndIndexing() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "metadata-refresh-race")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let session = LibraryFeatureFixture.diskSession(folder: folder)
        let blocker = SearchLoadBlocker()
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [RecordingSessionStore.session(for: folder, recordingURL: folder.appendingPathComponent("recording.m4a"))] },
            sessionReloader: { item in RecordingSessionStore.session(for: item.folderURL, recordingURL: item.recordingURL) },
            searchDocumentLoader: { blocker.load($0) }, recovery: { _ in }, trashHandler: { _ in true }
        )
        feature.seedCanonicalSessionsForTesting([session], workspace: folder.deletingLastPathComponent(), fence: .initial)
        let indexStarted = expectation(description: "metadata indexing started")
        blocker.onFirstBlocked = { indexStarted.fulfill() }
        let savedEvent = expectation(description: "one metadata event")
        var saveCount = 0
        feature.onMetadataSaved = { _ in saveCount += 1; savedEvent.fulfill() }

        let save = Task { await feature.saveMetadata(titleEdit: .manual("Updated"), tags: "tag", isFavorite: true, for: session, fence: .initial) }
        await fulfillment(of: [indexStarted], timeout: 1)
        feature.refresh(workspace: folder.deletingLastPathComponent(), fence: .initial)
        blocker.releaseFirst()
        let outcome = await save.value
        XCTAssertEqual(outcome, .saved(sessionID: session.id, .metadata))
        await fulfillment(of: [savedEvent], timeout: 1)
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(feature.session(withID: session.id)?.displayName, "Updated")
        XCTAssertEqual(feature.session(withID: session.id)?.searchDocument.metadataText, "Updated")
    }

    func testRefreshReconcilesOwnedImportWhoseIndexingIsInFlight() async throws {
        let root = try LibraryFeatureFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let importedFolder = root.appendingPathComponent("owned-import", isDirectory: true)
        try FileManager.default.createDirectory(at: importedFolder, withIntermediateDirectories: true)
        let imported = RecordingSession(
            id: importedFolder,
            folderURL: importedFolder,
            recordingURL: importedFolder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 1,
            fileSize: 1,
            metadata: .init(title: "Imported")
        )
        let blocker = SearchLoadBlocker()
        defer { blocker.releaseFirst() }
        let cleanupCalls = LockedCounter()
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [imported] },
            sessionReloader: { $0 },
            searchDocumentLoader: { blocker.load($0) },
            recovery: { _ in },
            trashHandler: { _ in true },
            audioImporter: { _, _ in imported },
            importedSessionCleanup: { _, _ in cleanupCalls.increment() }
        )
        feature.seedCanonicalSessionsForTesting([], workspace: root, fence: .initial)
        let indexingStarted = expectation(description: "import indexing started")
        blocker.onFirstBlocked = { indexingStarted.fulfill() }
        let refreshReconciled = expectation(description: "refresh hides imported disk artifact before canonical publication")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.isEmpty { refreshReconciled.fulfill() }
        }
        let importedReady = expectation(description: "one imported ready event")
        var importedEvents = 0
        feature.onImportedAudioReady = { _ in
            importedEvents += 1
            importedReady.fulfill()
        }

        let result = Task {
            await feature.importAudio(root.appendingPathComponent("source.m4a"), workspace: root, fence: .initial)
        }
        await fulfillment(of: [indexingStarted], timeout: 1)
        feature.refresh(workspace: root, fence: .initial)
        await fulfillment(of: [refreshReconciled], timeout: 1)
        blocker.releaseFirst()

        guard case .success = await result.value else {
            return XCTFail("same-artifact refresh must not fail an owned import")
        }
        await fulfillment(of: [importedReady], timeout: 1)
        XCTAssertEqual(importedEvents, 1)
        XCTAssertEqual(cleanupCalls.value, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedFolder.path))
    }

    func testRefreshReconcilesPersistedTranscriptWhoseIndexingIsInFlight() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "transcript-refresh-reconcile")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let session = LibraryFeatureFixture.diskSession(folder: folder)
        let blocker = SearchLoadBlocker { candidate in
            .init(
                metadataText: candidate.displayName,
                transcriptText: (try? TranscriptDocumentStore.read(in: candidate.folderURL)) ?? ""
            )
        }
        defer { blocker.releaseFirst() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [RecordingSessionStore.session(for: folder, recordingURL: folder.appendingPathComponent("recording.m4a"))] },
            sessionReloader: { $0 },
            searchDocumentLoader: { blocker.load($0) },
            recovery: { _ in },
            trashHandler: { _ in true }
        )
        feature.seedCanonicalSessionsForTesting([session], workspace: folder.deletingLastPathComponent(), fence: .initial)
        let indexingStarted = expectation(description: "transcript indexing started")
        blocker.onFirstBlocked = { indexingStarted.fulfill() }
        let refreshPublished = expectation(description: "refresh publishes persisted transcript session")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.first?.id == session.id { refreshPublished.fulfill() }
        }
        let edited = expectation(description: "one transcript edited event")
        var events = 0
        feature.onTranscriptEdited = { _ in events += 1; edited.fulfill() }

        let save = Task { await feature.saveTranscript("persisted after refresh", for: session, fence: .initial) }
        await fulfillment(of: [indexingStarted], timeout: 1)
        feature.refresh(workspace: folder.deletingLastPathComponent(), fence: .initial)
        await fulfillment(of: [refreshPublished], timeout: 1)
        blocker.releaseFirst()

        let outcome = await save.value
        XCTAssertEqual(outcome, .saved(sessionID: session.id, .transcript))
        await fulfillment(of: [edited], timeout: 1)
        XCTAssertEqual(events, 1)
        XCTAssertEqual(feature.session(withID: session.id)?.searchDocument.transcriptText, "persisted after refresh")
    }

    func testRefreshReconcilesPersistedMetadataWhoseReloadAndIndexingAreInFlight() async throws {
        let folder = try LibraryFeatureFixture.makeDiskSession(named: "metadata-refresh-reconcile")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let session = LibraryFeatureFixture.diskSession(folder: folder)
        let blocker = SearchLoadBlocker()
        defer { blocker.releaseFirst() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [RecordingSessionStore.session(for: folder, recordingURL: folder.appendingPathComponent("recording.m4a"))] },
            sessionReloader: { item in RecordingSessionStore.session(for: item.folderURL, recordingURL: item.recordingURL) },
            searchDocumentLoader: { blocker.load($0) },
            recovery: { _ in },
            trashHandler: { _ in true }
        )
        feature.seedCanonicalSessionsForTesting([session], workspace: folder.deletingLastPathComponent(), fence: .initial)
        let indexingStarted = expectation(description: "metadata indexing started")
        blocker.onFirstBlocked = { indexingStarted.fulfill() }
        let refreshReconciled = expectation(description: "refresh retains current metadata session while durable reload completes")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [session] { refreshReconciled.fulfill() }
        }
        let saved = expectation(description: "one metadata saved event")
        var events = 0
        feature.onMetadataSaved = { _ in events += 1; saved.fulfill() }

        let save = Task {
            await feature.saveMetadata(titleEdit: .manual("Updated"), tags: "tag", isFavorite: true, for: session, fence: .initial)
        }
        await fulfillment(of: [indexingStarted], timeout: 1)
        feature.refresh(workspace: folder.deletingLastPathComponent(), fence: .initial)
        await fulfillment(of: [refreshReconciled], timeout: 1)
        blocker.releaseFirst()

        let outcome = await save.value
        XCTAssertEqual(outcome, .saved(sessionID: session.id, .metadata))
        await fulfillment(of: [saved], timeout: 1)
        XCTAssertEqual(events, 1)
        XCTAssertEqual(feature.session(withID: session.id)?.displayName, "Updated")
        XCTAssertEqual(feature.session(withID: session.id)?.searchDocument.metadataText, "Updated")
    }

    func testRefreshReconcilesSuccessfulTrashWhoseHandlerIsStillInFlight() async {
        let session = LibraryFeatureFixture.session(named: "trash-refresh-reconcile")
        let loads = RefreshLoadSequencer(results: [[], [session]], blockOnCall: 0)
        let blocker = TrashBlocker()
        defer { blocker.release() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in loads.load() },
            sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument },
            recovery: { _ in },
            trashHandler: { _ in blocker.move() }
        )
        feature.seedCanonicalSessionsForTesting([session], workspace: LibraryFeatureFixture.workspace, fence: .initial)
        let handlerStarted = expectation(description: "trash handler started")
        blocker.onBlocked = { handlerStarted.fulfill() }
        let refreshReconciled = expectation(description: "refresh retains canonical session while trash is durable")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [session] { refreshReconciled.fulfill() }
        }
        let removed = expectation(description: "one session removed event")
        var events = 0
        feature.onSessionRemoved = { _ in events += 1; removed.fulfill() }

        let trash = Task { await feature.moveToTrash(session, fence: .initial) }
        await fulfillment(of: [handlerStarted], timeout: 1)
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [refreshReconciled], timeout: 1)
        blocker.release()

        guard case .success = await trash.value else {
            return XCTFail("same-workspace refresh must not invalidate a successful trash")
        }
        await fulfillment(of: [removed], timeout: 1)
        XCTAssertEqual(events, 1)
        XCTAssertEqual(feature.sessions, [])
        let tombstoneHeld = expectation(description: "tombstone prevents stale disk listing from returning")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.isEmpty { tombstoneHeld.fulfill() }
        }
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [tombstoneHeld], timeout: 1)
        XCTAssertEqual(feature.sessions, [])
    }

    func testSymlinkWorkspaceImportRefreshAndPublicationUseOnePhysicalSessionIdentity() async throws {
        let root = try LibraryFeatureFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let physicalWorkspace = root.appendingPathComponent("physical", isDirectory: true)
        let linkedWorkspace = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedWorkspace, withDestinationURL: physicalWorkspace)
        let physicalFolder = physicalWorkspace.appendingPathComponent("manual-import", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalFolder, withIntermediateDirectories: true)
        let physicalRecording = physicalFolder.appendingPathComponent("recording.m4a")
        try Data().write(to: physicalRecording)
        let linkedFolder = linkedWorkspace.appendingPathComponent("manual-import", isDirectory: true)
        let linkedSession = RecordingSession(
            id: linkedFolder,
            folderURL: linkedFolder,
            recordingURL: linkedFolder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 1,
            fileSize: 1,
            metadata: .init(title: "Imported through link")
        )
        let physicalSession = RecordingSession(
            id: physicalFolder,
            folderURL: physicalFolder,
            recordingURL: physicalRecording,
            createdAt: linkedSession.createdAt,
            duration: 1,
            fileSize: 1,
            metadata: linkedSession.metadata
        )
        let blocker = SearchLoadBlocker()
        defer { blocker.releaseFirst() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [physicalSession] },
            sessionReloader: { $0 },
            searchDocumentLoader: { blocker.load($0) },
            recovery: { _ in },
            trashHandler: { _ in true },
            audioImporter: { _, _ in linkedSession }
        )
        feature.seedCanonicalSessionsForTesting([], workspace: linkedWorkspace, fence: .initial)
        let indexingStarted = expectation(description: "linked import indexing started")
        blocker.onFirstBlocked = { indexingStarted.fulfill() }
        let refreshReconciled = expectation(description: "physical refresh hides linked import until canonical publication")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.isEmpty { refreshReconciled.fulfill() }
        }
        let ready = expectation(description: "one canonical imported event")
        var events = 0
        feature.onImportedAudioReady = { _ in events += 1; ready.fulfill() }

        let result = Task {
            await feature.importAudio(root.appendingPathComponent("source.m4a"), workspace: linkedWorkspace, fence: .initial)
        }
        await fulfillment(of: [indexingStarted], timeout: 1)
        feature.refresh(workspace: physicalWorkspace, fence: .initial)
        await fulfillment(of: [refreshReconciled], timeout: 1)
        blocker.releaseFirst()

        guard case .success(let imported) = await result.value else {
            return XCTFail("linked import must reconcile with the physical refresh")
        }
        await fulfillment(of: [ready], timeout: 1)
        XCTAssertEqual(events, 1)
        XCTAssertEqual(imported.id, physicalFolder)
        XCTAssertEqual(feature.sessions.map(\.id), [physicalFolder])
        XCTAssertEqual(feature.sessions.first?.folderURL, physicalFolder)
    }

    func testRefreshDeduplicatesAliasAndPhysicalSessionsBeforePublishingStates() async throws {
        let root = try LibraryFeatureFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let physicalWorkspace = root.appendingPathComponent("physical", isDirectory: true)
        let linkedWorkspace = root.appendingPathComponent("linked", isDirectory: true)
        let physicalFolder = physicalWorkspace.appendingPathComponent("meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedWorkspace, withDestinationURL: physicalWorkspace)
        let physicalRecording = physicalFolder.appendingPathComponent("recording.m4a")
        try Data().write(to: physicalRecording)
        let state = TranscriptionState(phase: .queued, message: "queued", startedAt: .now, finishedAt: nil)
        try TranscriptionStateStore.save(state, in: physicalFolder)
        let physical = RecordingSession(
            id: physicalFolder,
            folderURL: physicalFolder,
            recordingURL: physicalRecording,
            createdAt: .now,
            duration: 1,
            fileSize: 1,
            metadata: .init()
        )
        let aliasFolder = linkedWorkspace.appendingPathComponent("meeting", isDirectory: true)
        let alias = RecordingSession(
            id: aliasFolder,
            folderURL: aliasFolder,
            recordingURL: aliasFolder.appendingPathComponent("recording.m4a"),
            createdAt: physical.createdAt,
            duration: physical.duration,
            fileSize: physical.fileSize,
            metadata: physical.metadata
        )
        let loader = RefreshLoadSequencer(results: [[alias, physical]], blockOnCall: 1)
        defer { loader.release() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in loader.load() },
            sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument },
            recovery: { _ in },
            trashHandler: { _ in true }
        )
        let loaded = expectation(description: "one physical session and state publish")
        var loadedSnapshot: LibraryLoadedSnapshot?
        feature.onSessionsLoaded = { snapshot in
            loadedSnapshot = snapshot
            loaded.fulfill()
        }

        feature.refresh(workspace: linkedWorkspace, fence: .initial)
        XCTAssertTrue(loader.waitUntilBlocked(), "the queued loader must admit the refresh before completion is released")
        loader.release()
        await fulfillment(of: [loaded], timeout: 1)
        let canonicalFolder = RecordingLibraryURLIdentity.normalized(physicalFolder)
        XCTAssertEqual(feature.sessions.map(\.id), [canonicalFolder])
        XCTAssertEqual(loadedSnapshot?.transcriptionStates[canonicalFolder]?.phase, state.phase)
        XCTAssertEqual(loadedSnapshot?.transcriptionStates[canonicalFolder]?.message, state.message)
    }

    func testWorkspaceTransitionCleansOwnedImportAfterItsIndexingWasAlreadyQueued() async throws {
        let root = try LibraryFeatureFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let importedFolder = root.appendingPathComponent("owned-after-transition", isDirectory: true)
        try FileManager.default.createDirectory(at: importedFolder, withIntermediateDirectories: true)
        let imported = RecordingSession(
            id: importedFolder,
            folderURL: importedFolder,
            recordingURL: importedFolder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 1,
            fileSize: 1,
            metadata: .init()
        )
        let blocker = SearchLoadBlocker()
        defer { blocker.releaseFirst() }
        let cleanupCalls = LockedCounter()
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [] },
            sessionReloader: { $0 },
            searchDocumentLoader: { blocker.load($0) },
            recovery: { _ in },
            trashHandler: { _ in true },
            audioImporter: { _, _ in imported },
            importedSessionCleanup: { _, _ in cleanupCalls.increment() }
        )
        feature.seedCanonicalSessionsForTesting([], workspace: root, fence: .initial)
        let indexingStarted = expectation(description: "owned import indexing started")
        blocker.onFirstBlocked = { indexingStarted.fulfill() }

        let importing = Task {
            await feature.importAudio(root.appendingPathComponent("source.m4a"), workspace: root, fence: .initial)
        }
        await fulfillment(of: [indexingStarted], timeout: 1)
        feature.clearForWorkspaceChange()
        feature.refresh(workspace: root.appendingPathComponent("new", isDirectory: true), fence: .initial.advanced())
        blocker.releaseFirst()

        guard case .failure = await importing.value else {
            return XCTFail("a workspace transition must fail the queued import")
        }
        XCTAssertEqual(cleanupCalls.value, 1)
        XCTAssertTrue(feature.sessions.isEmpty)
    }

    func testAdvancedFenceRefreshAdoptsImportedArtifactWithoutCleaningItAfterOldTicketCompletes() async throws {
        let root = try LibraryFeatureFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let importedFolder = root.appendingPathComponent("adopted-import", isDirectory: true)
        try FileManager.default.createDirectory(at: importedFolder, withIntermediateDirectories: true)
        let imported = RecordingSession(
            id: importedFolder,
            folderURL: importedFolder,
            recordingURL: importedFolder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 1,
            fileSize: 1,
            metadata: .init(title: "Imported")
        )
        let blocker = SearchLoadBlocker()
        defer { blocker.releaseFirst() }
        let cleanupCalls = LockedCounter()
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [imported] },
            sessionReloader: { $0 },
            searchDocumentLoader: { blocker.load($0) },
            recovery: { _ in },
            trashHandler: { _ in true },
            audioImporter: { _, _ in imported },
            importedSessionCleanup: { _, _ in cleanupCalls.increment() }
        )
        feature.seedCanonicalSessionsForTesting([], workspace: root, fence: .initial)
        let indexingStarted = expectation(description: "old import ticket begins indexing")
        blocker.onFirstBlocked = { indexingStarted.fulfill() }
        let adopted = expectation(description: "advanced fence refresh adopts imported canonical session")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.map(\.id) == [RecordingLibraryURLIdentity.normalized(imported.id)] {
                adopted.fulfill()
            }
        }

        let importing = Task {
            await feature.importAudio(root.appendingPathComponent("source.m4a"), workspace: root, fence: .initial)
        }
        await fulfillment(of: [indexingStarted], timeout: 1)
        feature.refresh(workspace: root, fence: .initial.advanced())
        await fulfillment(of: [adopted], timeout: 1)
        blocker.releaseFirst()

        guard case .failure = await importing.value else {
            return XCTFail("the old fence import must report stale after the fence advances")
        }
        XCTAssertEqual(cleanupCalls.value, 0)
        XCTAssertEqual(feature.sessions.map(\.id), [RecordingLibraryURLIdentity.normalized(imported.id)])
    }

    func testAliasTranscriptPublicationIsRejectedBeforeCanonicalAdmission() async throws {
        let root = try LibraryFeatureFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let physicalWorkspace = root.appendingPathComponent("physical", isDirectory: true)
        let linkedWorkspace = root.appendingPathComponent("linked", isDirectory: true)
        let physicalFolder = physicalWorkspace.appendingPathComponent("meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedWorkspace, withDestinationURL: physicalWorkspace)
        let physical = RecordingSession(
            id: physicalFolder,
            folderURL: physicalFolder,
            recordingURL: physicalFolder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 1,
            fileSize: 1,
            metadata: .init()
        )
        let aliasFolder = linkedWorkspace.appendingPathComponent("meeting", isDirectory: true)
        let alias = RecordingSession(
            id: aliasFolder,
            folderURL: aliasFolder,
            recordingURL: aliasFolder.appendingPathComponent("recording.m4a"),
            createdAt: physical.createdAt,
            duration: 1,
            fileSize: 1,
            metadata: physical.metadata
        )
        let searchLoads = LockedCounter()
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [physical] },
            sessionReloader: { $0 },
            searchDocumentLoader: { _ in
                searchLoads.increment()
                return .init(metadataText: "indexed", transcriptText: "")
            },
            recovery: { _ in },
            trashHandler: { _ in true }
        )
        feature.seedCanonicalSessionsForTesting([physical], workspace: physicalWorkspace, fence: .initial)
        let canonicalCommitted = expectation(description: "canonical publication commits after the rejected alias")
        var committedEvents = 0
        feature.onTranscriptPublicationCommitted = { _ in
            committedEvents += 1
            canonicalCommitted.fulfill()
        }

        feature.acceptTranscriptPublication(LibraryFeatureFixture.publication(for: alias, fence: .initial))
        XCTAssertEqual(searchLoads.value, 0, "an alias must be rejected before it can schedule indexing")
        XCTAssertEqual(committedEvents, 0, "an alias must be rejected before it can invoke publication callbacks")

        feature.acceptTranscriptPublication(LibraryFeatureFixture.publication(for: physical, fence: .initial))
        await fulfillment(of: [canonicalCommitted], timeout: 1)
        XCTAssertEqual(searchLoads.value, 1, "only the canonical publication may index")
        XCTAssertEqual(committedEvents, 1, "only the canonical publication may commit")
        XCTAssertEqual(feature.sessions.map(\.id), [physical.id])
        XCTAssertEqual(feature.sessions.first?.folderURL, physical.folderURL)
        XCTAssertEqual(feature.sessions.first?.searchDocument.metadataText, "indexed")
    }

    func testObsoleteOrFailedImportPublishesNoReadyEvent() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let feature = LibraryFeatureModel(sessionLoader: { _ in [] }, sessionReloader: { $0 }, searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true })
        feature.refresh(workspace: root, fence: .initial)
        var eventCount = 0
        feature.onImportedAudioReady = { _ in eventCount += 1 }
        guard case .failure = await feature.importAudio(root.appendingPathComponent("missing.m4a"), workspace: root, fence: .initial) else { return XCTFail("Expected failure") }
        XCTAssertEqual(eventCount, 0)
    }

    func testFailedImportMakesNoVisibleSnapshotPublication() async throws {
        let root = try LibraryFeatureFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true }
        )
        feature.seedCanonicalSessionsForTesting([], workspace: root, fence: .initial)
        let before = feature.snapshot
        var publications = 0
        let cancellable = feature.$snapshot.dropFirst().sink { _ in publications += 1 }

        guard case .failure = await feature.importAudio(
            root.appendingPathComponent("missing.m4a"), workspace: root, fence: .initial
        ) else { return XCTFail("Expected import failure") }
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(feature.snapshot, before)
        XCTAssertTrue(feature.sessions.isEmpty)
        withExtendedLifetime(cancellable) {}
    }

    func testTrashTombstonesBeforeOneRemovalEvent() async {
        let session = LibraryFeatureFixture.session(named: "trash")
        let feature = LibraryFeatureModel(sessionLoader: { _ in [session] }, sessionReloader: { $0 }, searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true })
        let initiallyLoaded = expectation(description: "session is canonical before trash")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [session] { initiallyLoaded.fulfill() }
        }
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [initiallyLoaded], timeout: 1)
        var eventSessions: [[RecordingSession]] = []
        var removedEvents: [SessionRemoved] = []
        feature.onSessionRemoved = { event in
            removedEvents.append(event)
            eventSessions.append(feature.sessions)
        }
        _ = await feature.moveToTrash(session, fence: .initial)
        XCTAssertEqual(eventSessions, [[]])
        XCTAssertEqual(removedEvents.count, 1)
        XCTAssertEqual(removedEvents.first?.identity.librarySourceID, feature.librarySourceID)
        XCTAssertEqual(removedEvents.first?.identity.workspaceFence, .initial)
        XCTAssertEqual(removedEvents.first?.identity.normalizedSessionFolder,
                       RecordingLibraryURLIdentity.normalized(session.folderURL))

        let refreshedWithoutTombstone = expectation(description: "refresh cannot resurrect trashed session")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.isEmpty { refreshedWithoutTombstone.fulfill() }
        }
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [refreshedWithoutTombstone], timeout: 1)
        XCTAssertTrue(feature.sessions.isEmpty)
    }

    func testTrashFailureKeepsCanonicalSessionAndEmitsNothing() async {
        let session = LibraryFeatureFixture.session(named: "trash-failure")
        let feature = LibraryFeatureModel(sessionLoader: { _ in [session] }, sessionReloader: { $0 }, searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in throw LibraryFeatureFailure(message: "failed") })
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        feature.seedCanonicalSessionsForTesting(
            [session], workspace: LibraryFeatureFixture.workspace, fence: .initial
        )
        var eventCount = 0
        feature.onSessionRemoved = { _ in eventCount += 1 }
        guard case .failure = await feature.moveToTrash(session, fence: .initial) else { return XCTFail("Expected failure") }
        XCTAssertEqual(feature.sessions, [session])
        XCTAssertEqual(eventCount, 0)
    }

    func testTrashFalseKeepsCanonicalSessionAndEmitsNothing() async {
        let session = LibraryFeatureFixture.session(named: "trash-false")
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [session] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in false }
        )
        feature.seedCanonicalSessionsForTesting(
            [session], workspace: LibraryFeatureFixture.workspace, fence: .initial
        )
        var events = 0
        feature.onSessionRemoved = { _ in events += 1 }

        guard case .failure = await feature.moveToTrash(session, fence: .initial)
        else { return XCTFail("false handler must be failure") }
        XCTAssertEqual(feature.sessions, [session])
        XCTAssertEqual(events, 0)
    }

    func testConcurrentTrashOnlyMovesCanonicalSessionOnce() async {
        let session = LibraryFeatureFixture.session(named: "concurrent-trash")
        let blocker = TrashBlocker()
        defer { blocker.release() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [session] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in blocker.move() }
        )
        feature.seedCanonicalSessionsForTesting(
            [session], workspace: LibraryFeatureFixture.workspace, fence: .initial
        )
        var removals = 0
        feature.onSessionRemoved = { _ in removals += 1 }
        let handlerStarted = expectation(description: "first trash handler started")
        blocker.onBlocked = { handlerStarted.fulfill() }

        let winner = Task { await feature.moveToTrash(session, fence: .initial) }
        await fulfillment(of: [handlerStarted], timeout: 1)
        let loser = await feature.moveToTrash(session, fence: .initial)
        blocker.release()
        guard case .success = await winner.value else { return XCTFail("first request should win") }
        guard case .failure = loser else { return XCTFail("duplicate request must not succeed") }

        XCTAssertEqual(blocker.calls, 1)
        XCTAssertTrue(feature.sessions.isEmpty)
        XCTAssertEqual(removals, 1)
    }

    func testTrashRejectsSameIDWithDifferentCanonicalArtifact() async {
        let session = LibraryFeatureFixture.session(named: "canonical-trash")
        let wrongFolder = LibraryFeatureFixture.workspace.appendingPathComponent("forged", isDirectory: true)
        let forged = RecordingSession(
            id: session.id, folderURL: wrongFolder,
            recordingURL: wrongFolder.appendingPathComponent("recording.m4a"),
            createdAt: session.createdAt, duration: session.duration, fileSize: session.fileSize,
            metadata: session.metadata
        )
        let calls = LockedCounter()
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [session] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in calls.increment(); return true }
        )
        feature.seedCanonicalSessionsForTesting([session], workspace: LibraryFeatureFixture.workspace, fence: .initial)
        guard case .failure = await feature.moveToTrash(forged, fence: .initial) else {
            return XCTFail("forged same-ID session must be rejected")
        }
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(feature.sessions, [session])
    }

    func testStaleImportedSessionIsCleanedBeforeFailureReturns() async throws {
        let root = try LibraryFeatureFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("audio.m4a")
        try Data([1]).write(to: source)
        let blocker = ImportBlocker()
        defer { blocker.release() }
        let importedFolder = root.appendingPathComponent("owned-import", isDirectory: true)
        let imported = RecordingSession(
            id: importedFolder, folderURL: importedFolder,
            recordingURL: importedFolder.appendingPathComponent("recording.m4a"),
            createdAt: .now, duration: 0, fileSize: 0, metadata: .init()
        )
        let cleaned = expectation(description: "owned import cleaned")
        let importStarted = expectation(description: "importer is in flight")
        blocker.onBlocked = { importStarted.fulfill() }
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in },
            trashHandler: { _ in true },
            audioImporter: { _, _ in
                try FileManager.default.createDirectory(at: importedFolder, withIntermediateDirectories: true)
                blocker.wait()
                return imported
            },
            importedSessionCleanup: { session, workspace in
                guard session.folderURL.deletingLastPathComponent() == workspace else { return }
                try? FileManager.default.removeItem(at: session.folderURL)
                cleaned.fulfill()
            }
        )
        feature.refresh(workspace: root, fence: .initial)
        let task = Task { await feature.importAudio(source, workspace: root, fence: .initial) }
        await fulfillment(of: [importStarted], timeout: 1)
        feature.clearForWorkspaceChange()
        feature.refresh(workspace: root.appendingPathComponent("new"), fence: .initial.advanced())
        blocker.release()
        guard case .failure = await task.value else { return XCTFail("stale import must fail") }
        await fulfillment(of: [cleaned], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: importedFolder.path))
        XCTAssertTrue(feature.sessions.isEmpty)
    }

    func testAdvancedFenceRefreshAdoptsArtifactWhileImporterIsBlockedWithoutOldFlowCleaningIt() async throws {
        let root = try LibraryFeatureFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        try Data([1]).write(to: source)
        let importedFolder = root.appendingPathComponent("import-visible-before-return", isDirectory: true)
        let imported = RecordingSession(
            id: importedFolder, folderURL: importedFolder,
            recordingURL: importedFolder.appendingPathComponent("recording.m4a"),
            createdAt: .now, duration: 1, fileSize: 1, metadata: .init(title: "Imported")
        )
        let importer = ImportBlocker()
        defer { importer.release() }
        let cleanupCalls = LockedCounter()
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in
                FileManager.default.fileExists(atPath: importedFolder.path) ? [imported] : []
            },
            sessionReloader: { $0 }, searchDocumentLoader: { $0.searchDocument },
            recovery: { _ in }, trashHandler: { _ in true },
            audioImporter: { _, _ in
                try FileManager.default.createDirectory(at: importedFolder, withIntermediateDirectories: true)
                importer.wait()
                return imported
            },
            importedSessionCleanup: { _, _ in cleanupCalls.increment() }
        )
        feature.seedCanonicalSessionsForTesting([], workspace: root, fence: .initial)
        let importerStarted = expectation(description: "importer creates its artifact then blocks")
        importer.onBlocked = { importerStarted.fulfill() }
        let adopted = expectation(description: "advanced fence refresh adopts artifact")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.map(\.id) == [RecordingLibraryURLIdentity.normalized(imported.id)] {
                adopted.fulfill()
            }
        }

        let importing = Task { await feature.importAudio(source, workspace: root, fence: .initial) }
        await fulfillment(of: [importerStarted], timeout: 1)
        feature.refresh(workspace: root, fence: .initial.advanced())
        await fulfillment(of: [adopted], timeout: 1)
        importer.release()

        guard case .failure = await importing.value else {
            return XCTFail("the old-fence importer must fail after the fence advances")
        }
        XCTAssertEqual(cleanupCalls.value, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedFolder.path))
        XCTAssertEqual(feature.sessions.map(\.id), [RecordingLibraryURLIdentity.normalized(imported.id)])
    }

    func testShutdownWhileImporterIsBlockedLeavesUnpublishedArtifactForNextScanWithoutCleanupOrEvents() async throws {
        let root = try LibraryFeatureFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        try Data([1]).write(to: source)
        let importedFolder = root.appendingPathComponent("orphan-after-shutdown", isDirectory: true)
        let imported = RecordingSession(
            id: importedFolder, folderURL: importedFolder,
            recordingURL: importedFolder.appendingPathComponent("recording.m4a"),
            createdAt: .now, duration: 1, fileSize: 1, metadata: .init()
        )
        let importer = ImportBlocker()
        defer { importer.release() }
        let cleanupCalls = LockedCounter()
        let importedEvents = LockedCounter()
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in [] }, sessionReloader: { $0 },
            searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true },
            audioImporter: { _, _ in
                try FileManager.default.createDirectory(at: importedFolder, withIntermediateDirectories: true)
                importer.wait()
                return imported
            },
            importedSessionCleanup: { _, _ in cleanupCalls.increment() }
        )
        feature.seedCanonicalSessionsForTesting([], workspace: root, fence: .initial)
        feature.onImportedAudioReady = { _ in importedEvents.increment() }
        let importerStarted = expectation(description: "importer blocks before publication")
        importer.onBlocked = { importerStarted.fulfill() }

        let importing = Task { await feature.importAudio(source, workspace: root, fence: .initial) }
        await fulfillment(of: [importerStarted], timeout: 1)
        feature.shutdown()
        importer.release()

        guard case .failure = await importing.value else {
            return XCTFail("shutdown must reject the late import")
        }
        XCTAssertEqual(cleanupCalls.value, 0)
        XCTAssertEqual(importedEvents.value, 0)
        XCTAssertTrue(feature.snapshot.sessions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedFolder.path))
    }

    func testRefreshCannotAdoptAnArtifactWhileItsStaleImportCleanupIsInFlight() async throws {
        let root = try LibraryFeatureFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let otherWorkspace = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherWorkspace, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.m4a")
        try Data([1]).write(to: source)
        let importedFolder = root.appendingPathComponent("cleanup-reserved", isDirectory: true)
        let imported = RecordingSession(
            id: importedFolder, folderURL: importedFolder,
            recordingURL: importedFolder.appendingPathComponent("recording.m4a"),
            createdAt: .now, duration: 1, fileSize: 1, metadata: .init(title: "Reserved")
        )
        let indexer = SearchLoadBlocker()
        let cleanup = ImportBlocker()
        let staleRefreshLoader = RefreshLoadSequencer(results: [[imported], []], blockOnCall: 1)
        defer { indexer.releaseFirst(); cleanup.release(); staleRefreshLoader.release() }
        let normalizedRoot = RecordingLibraryURLIdentity.normalized(root)
        let feature = LibraryFeatureModel(
            sessionLoader: { workspace in
                RecordingLibraryURLIdentity.normalized(workspace) == normalizedRoot
                    ? staleRefreshLoader.load()
                    : []
            },
            sessionReloader: { $0 }, searchDocumentLoader: { indexer.load($0) },
            recovery: { _ in }, trashHandler: { _ in true },
            audioImporter: { _, _ in
                try FileManager.default.createDirectory(at: importedFolder, withIntermediateDirectories: true)
                return imported
            },
            importedSessionCleanup: { session, _ in
                cleanup.wait()
                try? FileManager.default.removeItem(at: session.folderURL)
            }
        )
        feature.seedCanonicalSessionsForTesting([], workspace: root, fence: .initial)
        let indexingStarted = expectation(description: "import indexing is blocked")
        indexer.onFirstBlocked = { indexingStarted.fulfill() }
        let cleanupStarted = expectation(description: "stale cleanup reservation is active")
        cleanup.onBlocked = { cleanupStarted.fulfill() }
        let importing = Task { await feature.importAudio(source, workspace: root, fence: .initial) }
        await fulfillment(of: [indexingStarted], timeout: 1)

        feature.clearForWorkspaceChange()
        feature.refresh(workspace: otherWorkspace, fence: .initial.advanced())
        indexer.releaseFirst()
        await fulfillment(of: [cleanupStarted], timeout: 1)

        let reservationRefresh = expectation(description: "refresh cannot publish cleanup-reserved artifact")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.isEmpty { reservationRefresh.fulfill() }
        }
        let returnedFence = WorkspacePublicationFence.initial.advanced().advanced()
        feature.refresh(workspace: root, fence: returnedFence)
        XCTAssertTrue(
            staleRefreshLoader.waitUntilBlocked(),
            "the loader must read the artifact before stale cleanup finishes"
        )

        cleanup.release()
        guard case .failure = await importing.value else {
            return XCTFail("the stale import must fail after cleanup")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: importedFolder.path))
        staleRefreshLoader.release()
        await fulfillment(of: [reservationRefresh], timeout: 1)
        XCTAssertTrue(feature.sessions.isEmpty)

        let afterCleanupRefresh = expectation(description: "cleanup completion leaves no ghost projection")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions.isEmpty { afterCleanupRefresh.fulfill() }
        }
        feature.refresh(workspace: root, fence: returnedFence)
        await fulfillment(of: [afterCleanupRefresh], timeout: 1)
        XCTAssertTrue(feature.sessions.isEmpty)
    }

    func testShutdownClearsCallbacksAndRejectsLateLoadCompletion() async {
        let blocker = RefreshBlocker()
        defer { blocker.release() }
        let session = LibraryFeatureFixture.session(named: "late")
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in blocker.blockFirstLoad(); return [session] },
            sessionReloader: { $0 }, searchDocumentLoader: { $0.searchDocument },
            recovery: { _ in }, trashHandler: { _ in true }
        )
        var callbacks = 0
        feature.onSessionsLoaded = { _ in callbacks += 1 }
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        XCTAssertTrue(blocker.waitUntilBlocked())
        let unexpectedSnapshot = expectation(
            description: "shutdown suppresses direct and queued publications"
        )
        unexpectedSnapshot.isInverted = true
        let cancellable = feature.$snapshot.dropFirst().sink { _ in
            unexpectedSnapshot.fulfill()
        }
        feature.shutdown()
        let shutdownSnapshot = feature.snapshot
        feature.clearForWorkspaceChange()
        feature.seedCanonicalSessionsForTesting(
            [session],
            workspace: LibraryFeatureFixture.workspace,
            fence: .initial
        )
        blocker.release()
        await fulfillment(of: [unexpectedSnapshot], timeout: 0.1)
        XCTAssertEqual(feature.snapshot, shutdownSnapshot)
        XCTAssertEqual(callbacks, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testSnapshotRevisionAdvancesExactlyOnceForSeedAndClear() async {
        let session = LibraryFeatureFixture.session(named: "revision")
        let feature = LibraryFeatureModel(sessionLoader: { _ in [] }, sessionReloader: { $0 }, searchDocumentLoader: { $0.searchDocument }, recovery: { _ in }, trashHandler: { _ in true })
        var publications: [LibraryFeatureSnapshot] = []
        let seeded = expectation(description: "seed")
        let cleared = expectation(description: "clear")
        let cancellable = feature.$snapshot.dropFirst().sink { snapshot in
            publications.append(snapshot)
            if snapshot.sessions == [session] { seeded.fulfill() }
            if snapshot.sessions.isEmpty, publications.count == 2 { cleared.fulfill() }
        }
        feature.seedCanonicalSessionsForTesting([session], workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [seeded], timeout: 1)
        feature.clearForWorkspaceChange()
        await fulfillment(of: [cleared], timeout: 1)
        XCTAssertEqual(publications.map(\.revision), [1, 2])
        withExtendedLifetime(cancellable) {}
    }

    func testTranscriptSearchIndexPublishesExactlyOneRevision() async {
        let session = LibraryFeatureFixture.session(named: "search-revision")
        let document = RecordingLibrarySearchDocument(metadataText: "metadata", transcriptText: "searchable")
        let feature = LibraryFeatureModel(sessionLoader: { _ in [] }, sessionReloader: { $0 }, searchDocumentLoader: { _ in document }, recovery: { _ in }, trashHandler: { _ in true })
        feature.seedCanonicalSessionsForTesting([session], workspace: LibraryFeatureFixture.workspace, fence: .initial)
        let before = feature.snapshot.revision
        let updated = expectation(description: "indexed")
        var count = 0
        let cancellable = feature.$snapshot.dropFirst().sink { snapshot in
            count += 1
            if snapshot.sessions.first?.searchDocument == document { updated.fulfill() }
        }
        feature.acceptTranscriptPublication(LibraryFeatureFixture.publication(for: session, fence: .initial))
        await fulfillment(of: [updated], timeout: 1)
        XCTAssertEqual(feature.snapshot.revision, before + 1)
        XCTAssertEqual(count, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testMeetingIntelligenceReloadPublishesMetadataAndIndexExactlyOnce() async {
        let session = LibraryFeatureFixture.session(named: "mi-atomic")
        let reloaded = RecordingSession(id: session.id, folderURL: session.folderURL, recordingURL: session.recordingURL, createdAt: session.createdAt, duration: session.duration, fileSize: session.fileSize, metadata: .init(title: "Updated"))
        let document = RecordingLibrarySearchDocument(metadataText: "Updated", transcriptText: "")
        let feature = LibraryFeatureModel(sessionLoader: { _ in [session] }, sessionReloader: { _ in reloaded }, searchDocumentLoader: { _ in document }, recovery: { _ in }, trashHandler: { _ in true })
        feature.seedCanonicalSessionsForTesting([session], workspace: LibraryFeatureFixture.workspace, fence: .initial)
        let before = feature.snapshot.revision
        let updated = expectation(description: "atomic reload")
        var count = 0
        let cancellable = feature.$snapshot.dropFirst().sink { snapshot in
            count += 1
            if snapshot.sessions.first?.searchDocument == document { updated.fulfill() }
        }
        feature.refreshAfterMeetingIntelligence(session, fence: .initial)
        await fulfillment(of: [updated], timeout: 1)
        XCTAssertEqual(feature.snapshot.revision, before + 1)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(feature.snapshot.sessions.first?.displayName, "Updated")
        withExtendedLifetime(cancellable) {}
    }

    func testMeetingIntelligenceReloadReconcilesCompetingSameArtifactRefresh() async {
        let session = LibraryFeatureFixture.session(named: "mi-refresh-reconcile")
        let persisted = RecordingSession(
            id: session.id,
            folderURL: session.folderURL,
            recordingURL: session.recordingURL,
            createdAt: session.createdAt,
            duration: session.duration,
            fileSize: session.fileSize,
            metadata: .init(title: "Persisted title")
        )
        let competing = RecordingSession(
            id: session.id,
            folderURL: session.folderURL,
            recordingURL: session.recordingURL,
            createdAt: session.createdAt,
            duration: session.duration,
            fileSize: session.fileSize,
            metadata: .init(title: "Competing refresh")
        )
        let reload = ReloadSequencer(first: persisted, latest: persisted)
        defer { reload.releaseFirst() }
        let loads = RefreshLoadSequencer(results: [[competing], [persisted]], blockOnCall: 0)
        let feature = LibraryFeatureModel(
            sessionLoader: { _ in loads.load() },
            sessionReloader: { reload.load($0) },
            searchDocumentLoader: { .init(metadataText: $0.displayName, transcriptText: "") },
            recovery: { _ in },
            trashHandler: { _ in true }
        )
        feature.seedCanonicalSessionsForTesting([session], workspace: LibraryFeatureFixture.workspace, fence: .initial)
        let reloadStarted = expectation(description: "meeting intelligence reload started")
        reload.onFirstBlocked = { reloadStarted.fulfill() }
        let refreshReconciled = expectation(description: "competing refresh retains current canonical artifact")
        feature.onSessionsLoaded = { snapshot in
            if snapshot.sessions == [session] { refreshReconciled.fulfill() }
        }
        let persistedPublished = expectation(description: "persisted meeting intelligence title publishes")
        let cancellable = feature.$snapshot.dropFirst().sink { snapshot in
            if snapshot.sessions.first?.displayName == "Persisted title",
               snapshot.sessions.first?.searchDocument.metadataText == "Persisted title" {
                persistedPublished.fulfill()
            }
        }

        feature.refreshAfterMeetingIntelligence(session, fence: .initial)
        await fulfillment(of: [reloadStarted], timeout: 1)
        feature.refresh(workspace: LibraryFeatureFixture.workspace, fence: .initial)
        await fulfillment(of: [refreshReconciled], timeout: 1)
        reload.releaseFirst()

        await fulfillment(of: [persistedPublished], timeout: 1)
        XCTAssertEqual(feature.sessions.first?.displayName, "Persisted title")
        withExtendedLifetime(cancellable) {}
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() { lock.lock(); storage += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class RefreshBlocker: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var released = false
    func blockFirstLoad() {
        condition.lock(); blocked = true; condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }
    func waitUntilBlocked() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(1)
        while !blocked, condition.wait(until: deadline) {}
        return blocked
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

private final class RefreshLoadSequencer: @unchecked Sendable {
    private let condition = NSCondition()
    private let results: [[RecordingSession]]
    private let blockOnCall: Int
    private var calls = 0
    private var blocked = false
    private var released = false

    init(results: [[RecordingSession]], blockOnCall: Int) {
        self.results = results
        self.blockOnCall = blockOnCall
    }

    func load() -> [RecordingSession] {
        condition.lock()
        calls += 1
        let call = calls
        let result = results[min(call - 1, results.count - 1)]
        if call == blockOnCall {
            blocked = true
            condition.broadcast()
            while !released { condition.wait() }
        }
        condition.unlock()
        return result
    }

    func waitUntilBlocked() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(1)
        while !blocked, condition.wait(until: deadline) {}
        return blocked
    }

    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

private final class ReloadSequencer: @unchecked Sendable {
    private let condition = NSCondition()
    private let first: RecordingSession
    private let latest: RecordingSession
    private var calls = 0
    private var firstBlocked = false
    private var release = false
    var onFirstBlocked: (() -> Void)?
    var onFirstReturned: (() -> Void)?
    var onSecondCall: (() -> Void)?
    init(first: RecordingSession, latest: RecordingSession) { self.first = first; self.latest = latest }
    func load(_: RecordingSession) -> RecordingSession {
        condition.lock(); calls += 1
        let call = calls
        if call == 1 {
            firstBlocked = true; condition.broadcast()
            let onFirstBlocked = onFirstBlocked
            condition.unlock()
            onFirstBlocked?()
            condition.lock()
            while !release { condition.wait() }
            let onFirstReturned = onFirstReturned
            condition.unlock()
            onFirstReturned?()
            return first
        }
        let onSecondCall = call == 2 ? onSecondCall : nil
        condition.unlock()
        onSecondCall?()
        return latest
    }
    func releaseFirst() { condition.lock(); release = true; condition.broadcast(); condition.unlock() }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock(); private var storage = false
    func set(_ value: Bool) { lock.lock(); storage = value; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class SearchLoadBlocker: @unchecked Sendable {
    private let condition = NSCondition()
    private var callCount = 0
    private var firstBlocked = false
    private var firstReturned = false
    private var released = false
    private var titlesStorage: [String] = []
    private let documentBuilder: @Sendable (RecordingSession) -> RecordingLibrarySearchDocument
    var onFirstBlocked: (() -> Void)?
    var onFirstReturned: (() -> Void)?
    var onSecondCall: (() -> Void)?

    init(documentBuilder: @escaping @Sendable (RecordingSession) -> RecordingLibrarySearchDocument = {
        .init(metadataText: $0.displayName, transcriptText: "")
    }) {
        self.documentBuilder = documentBuilder
    }

    func load(_ session: RecordingSession) -> RecordingLibrarySearchDocument {
        condition.lock()
        callCount += 1
        let call = callCount
        titlesStorage.append(session.displayName)
        if call == 1 {
            firstBlocked = true
            condition.broadcast()
            let onFirstBlocked = onFirstBlocked
            condition.unlock()
            onFirstBlocked?()
            condition.lock()
            while !released { condition.wait() }
            firstReturned = true
            condition.broadcast()
            let onFirstReturned = onFirstReturned
            condition.unlock()
            onFirstReturned?()
            condition.lock()
        } else if call == 2 {
            let onSecondCall = onSecondCall
            condition.unlock()
            onSecondCall?()
            condition.lock()
        }
        condition.unlock()
        return documentBuilder(session)
    }

    var titles: [String] {
        condition.lock(); defer { condition.unlock() }
        return titlesStorage
    }

    func releaseFirst() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

private final class ImportBlocker: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var released = false
    var onBlocked: (() -> Void)?
    func wait() {
        condition.lock(); blocked = true; condition.broadcast()
        let onBlocked = onBlocked
        condition.unlock()
        onBlocked?()
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

private final class TrashBlocker: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var callCount = 0
    var onBlocked: (() -> Void)?

    func move() -> Bool {
        condition.lock()
        callCount += 1
        let call = callCount
        guard call == 1 else {
            condition.unlock()
            return true
        }
        let onBlocked = onBlocked
        condition.unlock()
        onBlocked?()
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
        return true
    }

    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    var calls: Int { condition.lock(); defer { condition.unlock() }; return callCount }
}

enum LibraryFeatureFixture {
    static let workspace = URL(fileURLWithPath: "/tmp/library-feature-workspace")

    static func session(named name: String) -> RecordingSession {
        let folder = workspace.appendingPathComponent(name, isDirectory: true)
        return RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 1,
            fileSize: 1,
            metadata: .init()
        )
    }

    static func publication(
        for session: RecordingSession,
        fence: WorkspacePublicationFence
    ) -> TranscriptPublished {
        .init(
            session: session,
            canonicalURL: session.folderURL.appendingPathComponent("transcript.txt"),
            revision: .init(sha256: "test", byteCount: 1),
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
            identity: .init(coordinatorInstanceID: UUID(), generation: 1, attemptID: UUID()),
            workspaceFence: fence
        )
    }

    static func makeDiskSession(named name: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("manual-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("recording.m4a"))
        try RecordingSessionMetadataStore.save(.init(), in: folder)
        return folder
    }

    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func diskSession(folder: URL) -> RecordingSession {
        RecordingSessionStore.session(for: folder, recordingURL: folder.appendingPathComponent("recording.m4a"))
    }

    @MainActor static func diskFeature(session: RecordingSession) -> LibraryFeatureModel {
        LibraryFeatureModel(sessionLoader: { _ in [session] }, sessionReloader: { item in RecordingSessionStore.session(for: item.folderURL, recordingURL: item.recordingURL) }, searchDocumentLoader: { item in RecordingLibrarySearchDocument.load(folderURL: item.folderURL, displayName: item.displayName, createdAt: item.createdAt, metadata: item.metadata) }, recovery: { _ in }, trashHandler: { _ in true })
    }
}
