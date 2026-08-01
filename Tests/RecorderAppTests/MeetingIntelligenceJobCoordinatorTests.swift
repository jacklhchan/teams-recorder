import Combine
import Foundation
import XCTest
@testable import RecorderApp

@MainActor
final class MeetingIntelligenceJobCoordinatorTests: XCTestCase {
    func testConfirmedPublicationRunsDiscoveryGenerationAndOnePublication() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        let event = fixture.event(generation: 1)

        fixture.coordinator.handleTranscriptPublished(event)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.availability.requests, 1)
        XCTAssertEqual(fixture.generator.requests, 1)
        XCTAssertEqual(fixture.publisher.requests, 1)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
    }

    func testSnapshotUsesCanonicalPhysicalIdentityAndRejectsAliasLookup() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        fixture.coordinator.checkAvailability(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertNotNil(fixture.coordinator.snapshot.presentation(for: fixture.session))
        let alias = fixture.session.folderURL
            .appendingPathComponent("..")
            .appendingPathComponent(fixture.session.folderURL.lastPathComponent)
        let aliasedSession = RecordingSession(
            id: alias,
            folderURL: alias,
            recordingURL: alias.appendingPathComponent("recording.m4a"),
            createdAt: fixture.session.createdAt,
            duration: fixture.session.duration,
            fileSize: fixture.session.fileSize,
            metadata: fixture.session.metadata
        )
        XCTAssertNil(fixture.coordinator.snapshot.presentation(for: aliasedSession))
        fixture.coordinator.remove(sessionID: aliasedSession.id)
        XCTAssertNotNil(fixture.coordinator.snapshot.presentation(for: fixture.session))
        fixture.coordinator.remove(sessionID: fixture.session.id)
        XCTAssertNil(fixture.coordinator.snapshot.presentation(for: fixture.session))
    }

    func testSnapshotRevisionAdvancesOnlyForVisibleChangesAndWorkspaceReset() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        XCTAssertEqual(fixture.coordinator.snapshot.revision, 0)

        fixture.artifactStore.loaded = fixture.artifact(revision: fixture.reader.snapshot.revision)
        fixture.coordinator.reload(sessions: [fixture.session])
        await fixture.waitForIdle()
        let afterAvailability = fixture.coordinator.snapshot.revision
        XCTAssertGreaterThan(afterAvailability, 0)

        // Repeating the same final visible value does not replace snapshot.
        fixture.coordinator.reload(sessions: [fixture.session])
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.revision, afterAvailability)

        fixture.coordinator.remove(sessionID: fixture.session.id)
        let afterRemove = fixture.coordinator.snapshot.revision
        XCTAssertEqual(afterRemove, afterAvailability + 1)
        fixture.coordinator.remove(sessionID: fixture.session.id)
        XCTAssertEqual(fixture.coordinator.snapshot.revision, afterRemove)

        fixture.coordinator.resetForWorkspaceChange()
        XCTAssertEqual(fixture.coordinator.snapshot.revision, afterRemove + 1)
        fixture.coordinator.resetForWorkspaceChange()
        XCTAssertEqual(fixture.coordinator.snapshot.revision, afterRemove + 2)
    }

    func testFeatureObserverSeesCommittedSnapshotAfterCoordinatorMutation() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        let feature = MeetingIntelligenceFeatureModel(coordinator: fixture.coordinator)
        var observed: MeetingIntelligenceFeatureSnapshot?
        let cancellation = feature.objectWillChange.sink {
            observed = feature.snapshot
        }
        defer { cancellation.cancel() }

        feature.checkAvailability(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(observed?.revision, feature.snapshot.revision)
        XCTAssertEqual(
            observed?.presentation(for: fixture.session)?.presentation.phase,
            .notGenerated
        )
    }

    func testUnconfirmedAutomaticPublicationNeverGenerates() async throws {
        let fixture = try CoordinatorFixture(availability: .unconfirmed(.modelNotAdvertised))

        fixture.coordinator.handleTranscriptPublished(fixture.event(generation: 1))
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.availability.requests, 1)
        XCTAssertEqual(fixture.generator.requests, 0)
        XCTAssertEqual(fixture.publisher.requests, 0)
        XCTAssertEqual(
            fixture.coordinator.presentation(for: fixture.session).unavailableReason,
            .modelNotAdvertised
        )
    }

    func testCrossSourcePublicationIsRejectedBeforeAnyIOOrAvailability() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        var event = fixture.event(generation: 1)
        event = .init(session: event.session, canonicalURL: event.canonicalURL, revision: event.revision,
                      normalizedSessionFolder: event.normalizedSessionFolder,
                      identity: .init(coordinatorInstanceID: UUID(), generation: 1, attemptID: UUID()))

        fixture.coordinator.handleTranscriptPublished(event)
        await Task.yield()

        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 0)
    }

    func testExactDigestArtifactSkipsAutomaticDiscoveryAndGeneration() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        fixture.artifactStore.loaded = fixture.artifact(revision: fixture.reader.snapshot.revision)

        fixture.coordinator.handleTranscriptPublished(fixture.event(generation: 1))
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 0)
        XCTAssertEqual(fixture.publisher.requests, 0)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
    }

    func testCheckAvailabilityPerformsDiscoveryOnly() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)

        fixture.coordinator.checkAvailability(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.availability.requests, 1)
        XCTAssertEqual(fixture.generator.requests, 0)
        XCTAssertEqual(fixture.publisher.requests, 0)
    }

    func testManualGenerateBypassesDiscoveryButRejectsPlaceholder() async throws {
        let fixture = try CoordinatorFixture(availability: .unconfirmed(.discoveryUnsupported))

        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 1)
        XCTAssertEqual(fixture.publisher.requests, 1)

        fixture.repository.snapshotValue = try fixture.snapshot(llmModel: "legacy-unconfigured-llm")
        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.generator.requests, 1)
        XCTAssertEqual(
            fixture.coordinator.presentation(for: fixture.session).unavailableReason,
            .placeholderModel
        )
    }

    func testDuplicateOrOlderPublicationDoesNotRepeatAutomaticWork() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        let latest = fixture.event(generation: 2)
        fixture.coordinator.handleTranscriptPublished(latest)
        await fixture.waitForIdle()
        fixture.coordinator.handleTranscriptPublished(latest)
        fixture.coordinator.handleTranscriptPublished(fixture.event(generation: 1))
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.generator.requests, 1)
        XCTAssertEqual(fixture.publisher.requests, 1)
    }

    func testTranscriptSaveMarksChangedArtifactStaleWithoutAutomaticGeneration() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        fixture.artifactStore.loaded = fixture.artifact(revision: fixture.reader.snapshot.revision)
        fixture.reader.snapshot = .init(
            url: fixture.reader.snapshot.url,
            data: Data("changed".utf8),
            revision: .init(sha256: "sha256:changed", byteCount: 7)
        )

        fixture.coordinator.transcriptDidSave(fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .stale)
        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 0)
    }

    func testUnreadableAutomaticArtifactNeedsAttentionWithoutProviderRequests() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        fixture.artifactStore.loadError = MeetingIntelligenceStoreError.malformed

        fixture.coordinator.handleTranscriptPublished(fixture.event(generation: 1))
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .failed)
        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 0)
        XCTAssertEqual(fixture.publisher.requests, 0)
    }

    func testReloadDoesNotReplaceOrCancelActiveGeneration() async throws {
        let entered = expectation(description: "generator entered")
        let gate = GenerationGate()
        let blockingGenerator = BlockingCoordinatorGenerator(entered: entered, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, generatorOverride: blockingGenerator)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        // A scan that temporarily omits the session is observational; only an
        // explicit remove/trash path may cancel its work.
        fixture.coordinator.reload(sessions: [])
        await gate.release()
        await fixture.waitForIdle()

        XCTAssertEqual(blockingGenerator.requests, 1)
        XCTAssertEqual(fixture.publisher.requests, 1)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
    }

    func testReloadRestoresReadyStaleAndInterruptedPresentations() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        fixture.artifactStore.loaded = fixture.artifact(revision: fixture.reader.snapshot.revision)
        fixture.coordinator.reload(sessions: [fixture.session])
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)

        fixture.reader.snapshot = .init(url: fixture.reader.snapshot.url, data: Data("changed".utf8),
                                        revision: .init(sha256: "sha256:changed", byteCount: 7))
        fixture.coordinator.reload(sessions: [fixture.session])
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .stale)

        fixture.artifactStore.loaded = nil
        fixture.stateStore.loaded = .init(schemaVersion: 1, phase: .interrupted, message: "Interrupted",
                                          sourceTranscriptSHA256: nil, startedAt: .distantPast, finishedAt: .distantPast)
        fixture.coordinator.reload(sessions: [fixture.session])
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .interrupted)
    }

    func testCancellationSuppressesLateGeneratorProgress() async throws {
        let entered = expectation(description: "generator entered")
        let finished = expectation(description: "late generator completed")
        let gate = GenerationGate()
        let blockingGenerator = BlockingCoordinatorGenerator(entered: entered, finished: finished, gate: gate, emitsLateProgress: true)
        let fixture = try CoordinatorFixture(availability: .confirmed, generatorOverride: blockingGenerator)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        await fixture.waitForIdle()
        await gate.release()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .cancelled)
    }

    func testCancelledTerminalStateWinsAfterQueuedGeneratingWrite() async throws {
        let entered = expectation(description: "generating state save entered")
        let release = DispatchSemaphore(value: 0)
        let states = BlockingStateStore(entered: entered, release: release)
        let fixture = try CoordinatorFixture(availability: .confirmed, stateStoreOverride: states)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        release.signal()
        await fixture.waitForIdle()

        XCTAssertEqual(states.saved.map(\.phase), [.generating, .cancelled])
        XCTAssertEqual(states.saved.last?.phase, .cancelled)
    }

    func testSuccessfulGenerationEmitsOneSemanticPublicationCallback() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        var callbackCount = 0
        fixture.coordinator.onPublication = { _ in callbackCount += 1 }

        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(callbackCount, 1)
    }

    func testAutomaticPublicationCarriesCoordinatorSessionAttemptTranscriptWorkspaceAndKind() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        var publications: [MeetingIntelligencePublished] = []
        fixture.coordinator.onPublication = { publications.append($0) }
        let fence = WorkspacePublicationFence(revision: 42)

        fixture.coordinator.handleTranscriptPublished(
            fixture.event(generation: 7, workspaceFence: fence)
        )
        await fixture.waitForIdle()

        XCTAssertEqual(publications.count, 1)
        let identity = try XCTUnwrap(publications.first?.identity)
        XCTAssertEqual(identity.coordinatorInstanceID, fixture.publicationSourceID)
        XCTAssertEqual(identity.sessionID.path, fixture.session.id.path)
        XCTAssertEqual(identity.normalizedSessionFolder, RecordingLibraryURLIdentity.normalized(fixture.root))
        XCTAssertEqual(identity.generation, 1)
        XCTAssertEqual(identity.transcriptRevision, fixture.reader.snapshot.revision)
        XCTAssertEqual(identity.workspaceFence, fence)
        XCTAssertEqual(identity.kind, .artifactAndAutomaticTitle)
    }

    func testArtifactAndAutomaticTitleEmitOneCombinedPublication() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        var publications: [MeetingIntelligencePublished] = []
        fixture.coordinator.onPublication = { publications.append($0) }

        fixture.coordinator.handleTranscriptPublished(fixture.event(generation: 1))
        await fixture.waitForIdle()

        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications.first?.identity.kind, .artifactAndAutomaticTitle)
        XCTAssertEqual(publications.first?.artifact?.summary, "Summary")
        XCTAssertEqual(publications.first?.titleOutcome, .preserved)
    }

    func testProtectedAutomaticTitleIsOnePreservedOutcomeNotASecondEvent() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        var publications: [MeetingIntelligencePublished] = []
        fixture.coordinator.onPublication = { publications.append($0) }

        fixture.coordinator.generate(for: fixture.session, workspaceFence: .initial)
        await fixture.waitForIdle()

        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications.first?.titleOutcome, .preserved)
        XCTAssertEqual(publications.first?.identity.kind, .artifactAndAutomaticTitle)
    }

    func testManualGenerationPreservesItsAdmissionWorkspaceFence() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        var publications: [MeetingIntelligencePublished] = []
        fixture.coordinator.onPublication = { publications.append($0) }
        let fence = WorkspacePublicationFence(revision: 93)

        fixture.coordinator.generate(for: fixture.session, workspaceFence: fence)
        await fixture.waitForIdle()

        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications.first?.identity.workspaceFence, fence)
    }

    func testExplicitApplyEmitsOnlyWhenMetadataActuallyChanges() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed, titleApplierOverride: true)
        fixture.artifactStore.loaded = fixture.artifact(revision: fixture.reader.snapshot.revision)
        var publications: [MeetingIntelligencePublished] = []
        fixture.coordinator.onPublication = { publications.append($0) }
        let fence = WorkspacePublicationFence(revision: 18)
        let manualSession = RecordingSession(
            id: fixture.session.id,
            folderURL: fixture.session.folderURL,
            recordingURL: fixture.session.recordingURL,
            createdAt: fixture.session.createdAt,
            duration: fixture.session.duration,
            fileSize: fixture.session.fileSize,
            metadata: .init(title: "Manual title", titleOrigin: .manual)
        )
        fixture.titleMetadataStore?.metadata = manualSession.metadata
        fixture.coordinator.reload(sessions: [manualSession])

        fixture.coordinator.applySuggestedTitle(for: manualSession, workspaceFence: fence)
        await fixture.waitForIdle()
        let reloaded = RecordingSession(
            id: fixture.session.id,
            folderURL: fixture.session.folderURL,
            recordingURL: fixture.session.recordingURL,
            createdAt: fixture.session.createdAt,
            duration: fixture.session.duration,
            fileSize: fixture.session.fileSize,
            metadata: try XCTUnwrap(fixture.titleMetadataStore?.metadata)
        )
        fixture.coordinator.reload(sessions: [reloaded])
        // Replay the pre-publication callback value. The coordinator validates
        // its identity; the applier reloads metadata under the mutation gate
        // and rejects this stale manual capture without another write/event.
        fixture.coordinator.applySuggestedTitle(for: manualSession, workspaceFence: .initial)
        await fixture.waitForIdle()

        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(fixture.titleMetadataStore?.saveCount, 1)
        XCTAssertEqual(publications.first?.identity.kind, .explicitSuggestedTitle)
        XCTAssertEqual(publications.first?.artifact, nil)
        XCTAssertEqual(publications.first?.titleOutcome, .explicitApplied)
        XCTAssertEqual(publications.first?.identity.workspaceFence, fence)
    }

    func testCancellationBeforeDurableCommitEmitsNothing() async throws {
        let entered = expectation(description: "generator entered")
        let gate = GenerationGate()
        let fixture = try CoordinatorFixture(
            availability: .confirmed,
            generatorOverride: BlockingCoordinatorGenerator(entered: entered, gate: gate)
        )
        var publications: [MeetingIntelligencePublished] = []
        fixture.coordinator.onPublication = { publications.append($0) }

        fixture.coordinator.generate(for: fixture.session, workspaceFence: .initial)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        await gate.release()
        await fixture.waitForIdle()

        XCTAssertTrue(publications.isEmpty)
    }

    func testCancellationAfterDurableCommitStillEmitsExactlyOnce() async throws {
        let delivery = BlockingPublicationDelivery()
        let fixture = try CoordinatorFixture(
            availability: .confirmed,
            publicationDeliveryOverride: delivery
        )
        var publications: [MeetingIntelligencePublished] = []
        fixture.coordinator.onPublication = { publications.append($0) }

        fixture.coordinator.generate(for: fixture.session, workspaceFence: .initial)
        await fulfillment(of: [delivery.admitted], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        await delivery.release()
        await fixture.waitForIdle()

        XCTAssertEqual(publications.count, 1)
    }

    func testCancellationAfterExplicitTitleCommitStillEmitsExactlyOnce() async throws {
        let delivery = BlockingPublicationDelivery()
        let fixture = try CoordinatorFixture(
            availability: .confirmed,
            titleApplierOverride: true,
            publicationDeliveryOverride: delivery
        )
        fixture.artifactStore.loaded = fixture.artifact(revision: fixture.reader.snapshot.revision)
        var publications: [MeetingIntelligencePublished] = []
        fixture.coordinator.onPublication = { publications.append($0) }

        fixture.coordinator.applySuggestedTitle(for: fixture.session, workspaceFence: .initial)
        await fulfillment(of: [delivery.admitted], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        await delivery.release()
        await fixture.waitForIdle()

        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications.first?.identity.kind, .explicitSuggestedTitle)
    }

    func testFailureOrNoOpBeforeCommitEmitsNothing() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed, titleApplierOverride: true)
        fixture.artifactStore.loaded = fixture.artifact(revision: fixture.reader.snapshot.revision)
        fixture.titleMetadataStore?.metadata.title = "Manual title"
        fixture.titleMetadataStore?.metadata.titleOrigin = .manual
        var publications: [MeetingIntelligencePublished] = []
        fixture.coordinator.onPublication = { publications.append($0) }

        fixture.coordinator.applySuggestedTitle(for: fixture.session, workspaceFence: .initial)
        await fixture.waitForIdle()

        XCTAssertTrue(publications.isEmpty)
    }

    func testForgedNoncanonicalSessionEmitsNoPublication() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        let forged = RecordingSession(
            id: fixture.session.id,
            folderURL: fixture.root.appendingPathComponent("forged-alias"),
            recordingURL: fixture.session.recordingURL,
            createdAt: fixture.session.createdAt,
            duration: fixture.session.duration,
            fileSize: fixture.session.fileSize,
            metadata: fixture.session.metadata
        )
        var publications: [MeetingIntelligencePublished] = []
        fixture.coordinator.onPublication = { publications.append($0) }

        fixture.coordinator.generate(for: forged, workspaceFence: .initial)
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: forged.id)

        XCTAssertEqual(fixture.publisher.requests, 0)
        XCTAssertTrue(publications.isEmpty)
    }

    func testSymlinkAliasSessionIsRejectedBeforeAvailabilityGenerationAndPublication() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        let alias = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: fixture.root.path
        )
        defer { try? FileManager.default.removeItem(at: alias) }
        let aliasSession = RecordingSession(
            id: alias,
            folderURL: alias,
            recordingURL: alias.appendingPathComponent("recording.m4a"),
            createdAt: fixture.session.createdAt,
            duration: fixture.session.duration,
            fileSize: fixture.session.fileSize,
            metadata: fixture.session.metadata
        )
        var publications: [MeetingIntelligencePublished] = []
        fixture.coordinator.onPublication = { publications.append($0) }

        fixture.coordinator.generate(for: aliasSession, workspaceFence: .initial)
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: aliasSession.id)

        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 0)
        XCTAssertEqual(fixture.publisher.requests, 0)
        XCTAssertTrue(publications.isEmpty)
    }

    func testSymlinkAliasIsRejectedBeforeAvailabilityCheck() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        let alias = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("availability-alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: fixture.root.path)
        defer { try? FileManager.default.removeItem(at: alias) }
        let aliasSession = RecordingSession(
            id: alias, folderURL: alias,
            recordingURL: alias.appendingPathComponent("recording.m4a"),
            createdAt: fixture.session.createdAt, duration: fixture.session.duration,
            fileSize: fixture.session.fileSize, metadata: fixture.session.metadata
        )

        fixture.coordinator.checkAvailability(for: aliasSession, workspaceFence: .initial)
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: aliasSession.id)

        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.reader.requests, 0)
    }

    func testSymlinkCanonicalTranscriptURLIsRejectedBeforeAutomaticIO() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        let alias = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("transcript-alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: fixture.root.path)
        defer { try? FileManager.default.removeItem(at: alias) }
        let original = fixture.event(generation: 1)
        let forged = TranscriptPublished(
            session: original.session,
            canonicalURL: alias.appendingPathComponent(TranscriptDocumentStore.editableFileName),
            revision: original.revision,
            normalizedSessionFolder: original.normalizedSessionFolder,
            identity: original.identity,
            workspaceFence: original.workspaceFence
        )
        var publications: [MeetingIntelligencePublished] = []
        fixture.coordinator.onPublication = { publications.append($0) }

        fixture.coordinator.handleTranscriptPublished(forged)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.reader.requests, 0)
        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 0)
        XCTAssertEqual(fixture.publisher.requests, 0)
        XCTAssertTrue(publications.isEmpty)
    }

    func testSymlinkAtLiteralTranscriptPathIsRejectedBeforeAutomaticIO() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        let literalTranscriptURL = TranscriptDocumentStore.editableURL(in: fixture.root)
        let target = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("transcript-target-\(UUID().uuidString).txt")
        try Data("not the canonical transcript".utf8).write(to: target)
        try FileManager.default.removeItem(at: literalTranscriptURL)
        try FileManager.default.createSymbolicLink(
            atPath: literalTranscriptURL.path,
            withDestinationPath: target.path
        )
        defer { try? FileManager.default.removeItem(at: target) }

        fixture.coordinator.handleTranscriptPublished(fixture.event(generation: 1))
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.reader.requests, 0)
        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 0)
        XCTAssertEqual(fixture.publisher.requests, 0)
    }

    func testSymlinkAliasIsRejectedBeforeSuggestedTitleApplyIO() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed, titleApplierOverride: true)
        fixture.artifactStore.loaded = fixture.artifact(revision: fixture.reader.snapshot.revision)
        let alias = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("title-alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: fixture.root.path)
        defer { try? FileManager.default.removeItem(at: alias) }
        let aliasSession = RecordingSession(
            id: alias, folderURL: alias,
            recordingURL: alias.appendingPathComponent("recording.m4a"),
            createdAt: fixture.session.createdAt, duration: fixture.session.duration,
            fileSize: fixture.session.fileSize, metadata: fixture.session.metadata
        )
        var publications: [MeetingIntelligencePublished] = []
        fixture.coordinator.onPublication = { publications.append($0) }

        fixture.coordinator.applySuggestedTitle(for: aliasSession, workspaceFence: .initial)
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: aliasSession.id)

        XCTAssertEqual(fixture.reader.requests, 0)
        XCTAssertEqual(fixture.titleMetadataStore?.saveCount, 0)
        XCTAssertTrue(publications.isEmpty)
    }

    func testMeetingIntelligencePublicationValueContractsAreHashableAndSendable() {
        func requiresHashableAndSendable<T: Hashable & Sendable>(_: T.Type) {}
        requiresHashableAndSendable(TranscriptDocumentRevision.self)
        requiresHashableAndSendable(WorkspacePublicationFence.self)
        requiresHashableAndSendable(TranscriptPublicationIdentity.self)
        requiresHashableAndSendable(MeetingIntelligencePublicationIdentity.self)
        requiresHashableAndSendable(MeetingIntelligencePublicationKind.self)
    }

    func testGenerationRetainsExactProviderSnapshotAfterRepositoryChanges() async throws {
        let entered = expectation(description: "generator entered")
        let gate = GenerationGate()
        let generator = BlockingCoordinatorGenerator(entered: entered, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, generatorOverride: generator)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.repository.snapshotValue = try fixture.snapshot(llmModel: "changed-after-start")
        await gate.release()
        await fixture.waitForIdle()

        XCTAssertEqual(generator.capturedModels, ["llm"])
        XCTAssertEqual(fixture.publisher.capturedModels, ["llm"])
    }

    func testTwoSessionsMaintainIndependentAttempts() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        let second = RecordingSession(id: fixture.root.appendingPathComponent("second"),
                                      folderURL: fixture.root.appendingPathComponent("second"),
                                      recordingURL: fixture.root.appendingPathComponent("second/recording.m4a"),
                                      createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())

        fixture.coordinator.generate(for: fixture.session)
        fixture.coordinator.generate(for: second)
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: fixture.session.id)
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: second.id)

        XCTAssertEqual(fixture.publisher.requests, 2)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
        XCTAssertEqual(fixture.coordinator.presentation(for: second).phase, .ready)
    }

    func testRemoveThenReloadAllowsNewAttemptToPersist() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)

        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()
        fixture.coordinator.remove(sessionID: fixture.session.id)
        fixture.coordinator.reload(sessions: [fixture.session])
        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.publisher.requests, 2)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
    }

    func testCancellationDuringAvailabilityKeepsCancelledPresentation() async throws {
        let entered = expectation(description: "availability entered")
        let gate = GenerationGate()
        let availability = BlockingAvailability(entered: entered, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, availabilityOverride: availability)

        fixture.coordinator.checkAvailability(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        await fixture.waitForIdle()
        await gate.release()

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .cancelled)
    }

    func testCancellationAfterDurablePublisherReturnKeepsCancelledPresentationAndEmitsCallback() async throws {
        let entered = expectation(description: "publisher entered")
        let gate = GenerationGate()
        let publisher = BlockingPublisher(entered: entered, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, publisherOverride: publisher)
        var callbacks = 0
        fixture.coordinator.onPublication = { _ in callbacks += 1 }

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        await fixture.waitForIdle()
        await gate.release()
        await fulfillment(of: [publisher.finished], timeout: 1)

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .cancelled)
        XCTAssertEqual(callbacks, 1)
    }

    func testNewerReadyPresentationWinsWhenEarlierDurablePublisherReturnsLateAndEachEmitsOneCallback() async throws {
        let firstPublisherEntered = expectation(description: "first publisher entered")
        let firstPublisherReturned = expectation(description: "first publisher returned")
        let gate = GenerationGate()
        let generator = SequencedCoordinatorGenerator(contents: [
            .init(title: "A title", summary: "A summary"),
            .init(title: "B title", summary: "B summary")
        ])
        let publisher = FirstCallBlockingPublisher(
            firstEntered: firstPublisherEntered,
            firstReturned: firstPublisherReturned,
            gate: gate
        )
        let fixture = try CoordinatorFixture(
            availability: .confirmed,
            generatorOverride: generator,
            publisherOverride: publisher
        )
        let callbacks = CallbackCount()
        let bothCallbacks = expectation(description: "two durable publication callbacks")
        bothCallbacks.expectedFulfillmentCount = 2
        fixture.coordinator.onPublication = { _ in
            callbacks.increment()
            bothCallbacks.fulfill()
        }

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [firstPublisherEntered], timeout: 1)

        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).summary, "B summary")
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).suggestedTitle, "B title")
        XCTAssertEqual(callbacks.value, 1)

        await gate.release()
        await fulfillment(of: [firstPublisherReturned, bothCallbacks], timeout: 1)

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).summary, "B summary")
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).suggestedTitle, "B title")
        XCTAssertEqual(callbacks.value, 2)
        XCTAssertEqual(publisher.requests, 2)
    }

    func testRemoveInvalidatesBlockedGenerationWithoutLatePublication() async throws {
        let entered = expectation(description: "generator entered")
        let finished = expectation(description: "generator finished")
        let gate = GenerationGate()
        let generator = BlockingCoordinatorGenerator(entered: entered, finished: finished, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, generatorOverride: generator)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.remove(sessionID: fixture.session.id)
        await gate.release()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(fixture.publisher.requests, 0)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session), .empty)
    }

    func testShutdownInvalidatesBlockedGenerationWithoutLatePublication() async throws {
        let entered = expectation(description: "generator entered")
        let finished = expectation(description: "generator finished")
        let gate = GenerationGate()
        let generator = BlockingCoordinatorGenerator(entered: entered, finished: finished, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, generatorOverride: generator)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.shutdown()
        await gate.release()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(fixture.publisher.requests, 0)
        // shutdown retains the last projection for teardown safety; no late
        // work may publish or mutate it afterwards.
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase,
                       .generating(.init(stage: .generatingFinal, current: 0, total: 0)))
    }

    func testRemoveCancelsStateWriteQueuedBeforeCommitBoundary() async throws {
        let entered = expectation(description: "state write admitted")
        let released = expectation(description: "state admission released")
        let gate = GenerationGate()
        let scheduler = BlockingStateSaveScheduler(entered: entered, released: released, gate: gate)
        let states = RecordingStateStore()
        let fixture = try CoordinatorFixture(availability: .confirmed, stateStoreOverride: states,
                                             stateSaveSchedulerOverride: scheduler)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.remove(sessionID: fixture.session.id)
        await gate.release()
        await fulfillment(of: [released], timeout: 1)

        XCTAssertTrue(states.saved.isEmpty)
    }

    func testShutdownCancelsStateWriteQueuedBeforeCommitBoundary() async throws {
        let entered = expectation(description: "state write admitted")
        let released = expectation(description: "state admission released")
        let gate = GenerationGate()
        let scheduler = BlockingStateSaveScheduler(entered: entered, released: released, gate: gate)
        let states = RecordingStateStore()
        let fixture = try CoordinatorFixture(availability: .confirmed, stateStoreOverride: states,
                                             stateSaveSchedulerOverride: scheduler)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.shutdown()
        await gate.release()
        await fulfillment(of: [released], timeout: 1)

        XCTAssertTrue(states.saved.isEmpty)
    }

    func testRemoveAndWorkspaceResetInvalidateStateWritesWaitingForCommitAdmission() async throws {
        for action in ["remove", "workspace reset"] {
            let entered = expectation(description: "\(action) state commit admission")
            let released = expectation(description: "\(action) admission released")
            let gate = GenerationGate()
            let scheduler = CommitBlockingStateSaveScheduler(entered: entered, released: released, gate: gate)
            let states = RecordingStateStore()
            let fixture = try CoordinatorFixture(availability: .confirmed, stateStoreOverride: states,
                                                 stateSaveSchedulerOverride: scheduler)

            fixture.coordinator.generate(for: fixture.session)
            await fulfillment(of: [entered], timeout: 1)
            if action == "remove" {
                fixture.coordinator.remove(sessionID: fixture.session.id)
            } else {
                fixture.coordinator.resetForWorkspaceChange()
            }
            await gate.release()
            await fulfillment(of: [released], timeout: 1)
            XCTAssertTrue(states.saved.isEmpty, "\(action) must suppress the invalidated state save")
        }
    }

    func testCancellationBeforeCommitAdmissionSuppressesGeneratingStateButPersistsNewerCancellation() async throws {
        let entered = expectation(description: "state commit admission")
        let released = expectation(description: "state admission released")
        let gate = GenerationGate()
        let scheduler = CommitBlockingStateSaveScheduler(entered: entered, released: released, gate: gate)
        let states = RecordingStateStore()
        let fixture = try CoordinatorFixture(availability: .confirmed, stateStoreOverride: states,
                                             stateSaveSchedulerOverride: scheduler)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        await gate.release()
        await fulfillment(of: [released], timeout: 1)
        await fixture.waitForIdle()

        XCTAssertEqual(states.saved.map(\.phase), [.cancelled])
    }

    func testPostReservationInvalidationCommitsCurrentStateBeforeNewerCancellation() async throws {
        let entered = expectation(description: "state save entered after reservation")
        let release = DispatchSemaphore(value: 0)
        let states = BlockingStateStore(entered: entered, release: release)
        let fixture = try CoordinatorFixture(availability: .confirmed, stateStoreOverride: states)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        release.signal()
        await fixture.waitForIdle()

        XCTAssertEqual(states.saved.map(\.phase), [.generating, .cancelled])
    }

    func testWorkspaceResetSuppressesOldLateJobAndAcceptsNewWork() async throws {
        let entered = expectation(description: "old generator entered")
        let finished = expectation(description: "old generator finished")
        let gate = GenerationGate()
        let generator = BlockingCoordinatorGenerator(entered: entered, finished: finished, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, generatorOverride: generator)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.resetForWorkspaceChange()
        await gate.release()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(fixture.publisher.requests, 0)

        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.publisher.requests, 1)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
    }

    func testWorkspaceResetReturningToSameFolderKeepsStateWriteGenerationMonotonic() async throws {
        let states = RecordingStateStore()
        let fixture = try CoordinatorFixture(availability: .confirmed, stateStoreOverride: states)

        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()
        fixture.coordinator.regenerate(for: fixture.session)
        await fixture.waitForIdle()
        XCTAssertEqual(states.saved.count, 4)

        fixture.coordinator.resetForWorkspaceChange()
        fixture.coordinator.reload(sessions: [fixture.session])
        await fixture.waitForIdle()
        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(states.saved.count, 6)
        XCTAssertEqual(states.saved.last?.phase, .completed)
    }

    func testManualTranscriptLoadFailureShowsNeedsAttentionRatherThanStuckGenerating() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        fixture.reader.readError = SecureTranscriptReadError.missing

        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .failed)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).statusMessage, "Transcript needs attention.")
        XCTAssertEqual(fixture.generator.requests, 0)
    }

    func testOldSnapshotFailureAfterCancellationCannotOverwriteTerminalPresentation() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        let entered = expectation(description: "snapshot entered")
        let finished = expectation(description: "snapshot finished")
        let release = DispatchSemaphore(value: 0)
        fixture.repository.snapshotEntered = entered
        fixture.repository.snapshotFinished = finished
        fixture.repository.snapshotRelease = release
        fixture.repository.snapshotError = ProviderProfileValidationError.invalidBaseURL

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        release.signal()
        await fulfillment(of: [finished], timeout: 1)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .cancelled)
    }

    func testCallbackEmitsBeforeCompletedStateAdmissionAndSurvivesCancellation() async throws {
        let fixture = try callbackBlockedFixture()
        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [fixture.scheduler.completedAdmission], timeout: 1)
        XCTAssertEqual(fixture.callbackCount.value, 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: fixture.session.id)
        await fixture.scheduler.release()
        XCTAssertEqual(fixture.callbackCount.value, 1)
    }

    func testCallbackEmitsBeforeCompletedStateAdmissionAndSurvivesRemoval() async throws {
        let fixture = try callbackBlockedFixture()
        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [fixture.scheduler.completedAdmission], timeout: 1)
        XCTAssertEqual(fixture.callbackCount.value, 1)
        fixture.coordinator.remove(sessionID: fixture.session.id)
        await fixture.scheduler.release()
        XCTAssertEqual(fixture.callbackCount.value, 1)
    }

    func testCallbackEmitsBeforeCompletedStateAdmissionAndSurvivesShutdown() async throws {
        let fixture = try callbackBlockedFixture()
        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [fixture.scheduler.completedAdmission], timeout: 1)
        XCTAssertEqual(fixture.callbackCount.value, 1)
        fixture.coordinator.shutdown()
        await fixture.scheduler.release()
        XCTAssertEqual(fixture.callbackCount.value, 1)
    }

    private func callbackBlockedFixture() throws -> CallbackBlockedFixture {
        let scheduler = BlockSecondStateSaveScheduler()
        let fixture = try CoordinatorFixture(availability: .confirmed, stateSaveSchedulerOverride: scheduler)
        let callbackCount = CallbackCount()
        fixture.coordinator.onPublication = { _ in callbackCount.increment() }
        return .init(coordinator: fixture.coordinator, session: fixture.session, scheduler: scheduler, callbackCount: callbackCount)
    }
}

private struct CallbackBlockedFixture {
    let coordinator: MeetingIntelligenceJobCoordinator
    let session: RecordingSession
    let scheduler: BlockSecondStateSaveScheduler
    let callbackCount: CallbackCount
}

@MainActor
private final class CoordinatorFixture {
    let root: URL
    let session: RecordingSession
    let reader: CoordinatorTranscriptReader
    let repository: CoordinatorRepository
    let availability: CoordinatorAvailability
    let generator = CoordinatorGenerator()
    let publisher = CoordinatorPublisher()
    let artifactStore = CoordinatorArtifactStore()
    let stateStore = CoordinatorStateStore()
    let titleMetadataStore: CoordinatorMetadataStore?
    let coordinator: MeetingIntelligenceJobCoordinator
    let coordinatorInstanceID = UUID()
    let publicationSourceID = UUID()

    init(availability: MeetingIntelligenceAvailability,
         generatorOverride: (any MeetingIntelligenceGenerating)? = nil,
         stateStoreOverride: (any MeetingIntelligenceStateStoring)? = nil,
         availabilityOverride: (any MeetingIntelligenceAvailabilityChecking)? = nil,
         publisherOverride: (any MeetingIntelligencePublishing)? = nil,
         stateSaveSchedulerOverride: (any MeetingIntelligenceStateSaveScheduling)? = nil,
         titleApplierOverride: Bool = false,
         publicationDeliveryOverride: (any MeetingIntelligencePublicationDeliveryScheduling)? = nil) throws {
        root = RecordingLibraryURLIdentity.normalized(
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcriptURL = root.appendingPathComponent("transcript.txt")
        let data = Data("Original transcript".utf8)
        try data.write(to: transcriptURL)
        let revision = TranscriptDocumentRevision(sha256: "sha256:original", byteCount: data.count)
        reader = .init(snapshot: .init(url: transcriptURL, data: data, revision: revision))
        session = .init(id: root, folderURL: root, recordingURL: root.appendingPathComponent("recording.m4a"),
                        createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())
        repository = .init(snapshotValue: try Self.makeSnapshot(llmModel: "llm"))
        self.availability = .init(value: availability)
        let titleMetadataStore = titleApplierOverride ? CoordinatorMetadataStore() : nil
        self.titleMetadataStore = titleMetadataStore
        let titleApplier: MeetingIntelligenceSuggestedTitleApplier?
        if let titleMetadataStore {
            titleApplier = MeetingIntelligenceSuggestedTitleApplier(
                mutationGate: RecordingSessionMutationGate(),
                transcriptReader: reader,
                metadataStore: titleMetadataStore
            )
        } else { titleApplier = nil }
        coordinator = .init(providerRepository: repository, expectedPublicationSourceID: coordinatorInstanceID,
                            publicationSourceID: publicationSourceID, transcriptReader: reader,
                            availabilityChecker: availabilityOverride ?? self.availability, generator: generatorOverride ?? generator,
                            publisher: publisherOverride ?? publisher, artifactStore: artifactStore, stateStore: stateStoreOverride ?? stateStore,
                            titleApplier: titleApplier,
                            stateSaveScheduler: stateSaveSchedulerOverride ?? ImmediateTestStateSaveScheduler(),
                            publicationDeliveryScheduler: publicationDeliveryOverride ?? ImmediateMeetingIntelligencePublicationDeliveryScheduler(),
                            now: { .distantPast })
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func event(generation: UInt64, workspaceFence: WorkspacePublicationFence = .initial) -> TranscriptPublished {
        .init(session: session, canonicalURL: reader.snapshot.url, revision: reader.snapshot.revision,
              normalizedSessionFolder: root.standardizedFileURL,
              identity: .init(coordinatorInstanceID: coordinatorInstanceID, generation: generation, attemptID: UUID()),
              workspaceFence: workspaceFence)
    }

    func snapshot(llmModel: String) throws -> OpenAICompatibleProviderSnapshot { try Self.makeSnapshot(llmModel: llmModel) }
    func artifact(revision: TranscriptDocumentRevision) -> MeetingIntelligenceArtifact {
        .init(schemaVersion: 1, summary: "Old", suggestedTitle: "Old title", sourceTranscriptSHA256: revision.sha256,
              sourceTranscriptByteCount: revision.byteCount, model: "llm", generatedAt: .distantPast, intent: .generate)
    }

    func waitForIdle() async {
        await coordinator.waitUntilIdleForTesting(sessionID: session.id)
    }

    private static func makeSnapshot(llmModel: String) throws -> OpenAICompatibleProviderSnapshot {
        try .validated(profile: .validated(baseURLText: "http://127.0.0.1:8080", asrModel: "asr", llmModel: llmModel,
                                            language: "en", prompt: ""), apiKey: nil)
    }
}

private actor GenerationGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private final class BlockingCoordinatorGenerator: MeetingIntelligenceGenerating, @unchecked Sendable {
    let entered: XCTestExpectation
    let finished: XCTestExpectation?
    let gate: GenerationGate
    private(set) var requests = 0
    private(set) var capturedModels: [String] = []
    let emitsLateProgress: Bool
    init(entered: XCTestExpectation, finished: XCTestExpectation? = nil, gate: GenerationGate, emitsLateProgress: Bool = false) {
        self.entered = entered; self.finished = finished; self.gate = gate; self.emitsLateProgress = emitsLateProgress
    }
    func generate(transcript _: TranscriptDocumentSnapshot, snapshot: OpenAICompatibleProviderSnapshot,
                  onProgress: @escaping @Sendable (MeetingIntelligenceProgress) -> Void) async throws -> MeetingIntelligenceGeneratedContent {
        requests += 1
        capturedModels.append(snapshot.profile.llmModel)
        if requests == 1 { entered.fulfill() }
        await gate.wait()
        if emitsLateProgress { onProgress(.init(stage: .generatingFinal, current: 99, total: 99)) }
        if requests == 1 { finished?.fulfill() }
        return .init(title: "Generated", summary: "Summary")
    }
}

private final class BlockingAvailability: MeetingIntelligenceAvailabilityChecking, @unchecked Sendable {
    let entered: XCTestExpectation
    let gate: GenerationGate
    init(entered: XCTestExpectation, gate: GenerationGate) { self.entered = entered; self.gate = gate }
    func availability(for _: OpenAICompatibleProviderSnapshot) async -> MeetingIntelligenceAvailability {
        entered.fulfill()
        await gate.wait()
        return .confirmed
    }
}

private final class BlockingPublisher: MeetingIntelligencePublishing, @unchecked Sendable {
    let entered: XCTestExpectation
    let finished = XCTestExpectation(description: "publisher finished")
    let gate: GenerationGate
    init(entered: XCTestExpectation, gate: GenerationGate) { self.entered = entered; self.gate = gate }
    func publish(_ request: MeetingIntelligencePublicationRequest) async throws -> MeetingIntelligencePublicationOutcome {
        entered.fulfill()
        await gate.wait()
        finished.fulfill()
        return .init(artifact: .init(schemaVersion: 1, summary: request.content.summary, suggestedTitle: request.content.title,
                                     sourceTranscriptSHA256: request.sourceRevision.sha256,
                                     sourceTranscriptByteCount: request.sourceRevision.byteCount,
                                     model: request.snapshot.profile.llmModel, generatedAt: request.generatedAt, intent: request.intent),
                     titleWasApplied: false, titleWarning: nil)
    }
}

private final class FirstCallBlockingPublisher: MeetingIntelligencePublishing, @unchecked Sendable {
    let firstEntered: XCTestExpectation
    let firstReturned: XCTestExpectation
    let gate: GenerationGate
    private let lock = NSLock()
    private var blocksFirstCall = true
    private(set) var requests = 0

    init(firstEntered: XCTestExpectation, firstReturned: XCTestExpectation, gate: GenerationGate) {
        self.firstEntered = firstEntered
        self.firstReturned = firstReturned
        self.gate = gate
    }

    func publish(_ request: MeetingIntelligencePublicationRequest) async throws -> MeetingIntelligencePublicationOutcome {
        let blocks = lock.withLock {
            requests += 1
            defer { blocksFirstCall = false }
            return blocksFirstCall
        }
        if blocks {
            firstEntered.fulfill()
            await gate.wait()
            firstReturned.fulfill()
        }
        return .init(artifact: .init(schemaVersion: 1, summary: request.content.summary, suggestedTitle: request.content.title,
                                     sourceTranscriptSHA256: request.sourceRevision.sha256,
                                     sourceTranscriptByteCount: request.sourceRevision.byteCount,
                                     model: request.snapshot.profile.llmModel, generatedAt: request.generatedAt, intent: request.intent),
                     titleWasApplied: false, titleWarning: nil)
    }
}

private struct ImmediateTestStateSaveScheduler: MeetingIntelligenceStateSaveScheduling {
    func awaitAdmission() async {}
}

private final class BlockingStateSaveScheduler: MeetingIntelligenceStateSaveScheduling, @unchecked Sendable {
    let entered: XCTestExpectation
    let released: XCTestExpectation
    let gate: GenerationGate
    init(entered: XCTestExpectation, released: XCTestExpectation, gate: GenerationGate) {
        self.entered = entered; self.released = released; self.gate = gate
    }
    func awaitAdmission() async { entered.fulfill(); await gate.wait(); released.fulfill() }
}

private final class CommitBlockingStateSaveScheduler: MeetingIntelligenceStateSaveScheduling, @unchecked Sendable {
    let entered: XCTestExpectation
    let released: XCTestExpectation
    let gate: GenerationGate
    private let lock = NSLock()
    private var shouldBlock = true

    init(entered: XCTestExpectation, released: XCTestExpectation, gate: GenerationGate) {
        self.entered = entered
        self.released = released
        self.gate = gate
    }

    func awaitAdmission() async {}

    func awaitCommitAdmission() async {
        let block = lock.withLock { () -> Bool in
            guard shouldBlock else { return false }
            shouldBlock = false
            return true
        }
        guard block else { return }
        entered.fulfill()
        await gate.wait()
        released.fulfill()
    }
}

private final class BlockSecondStateSaveScheduler: MeetingIntelligenceStateSaveScheduling, @unchecked Sendable {
    let completedAdmission = XCTestExpectation(description: "completed state admission")
    private let gate = GenerationGate()
    private let lock = NSLock()
    private var count = 0
    func awaitAdmission() async {
        let call = lock.withLock { count += 1; return count }
        guard call == 2 else { return }
        completedAdmission.fulfill()
        await gate.wait()
    }
    func release() async { await gate.release() }
}

private final class BlockingPublicationDelivery: MeetingIntelligencePublicationDeliveryScheduling, @unchecked Sendable {
    let admitted = XCTestExpectation(description: "durable publication delivery admitted")
    private let gate = GenerationGate()

    func awaitDeliveryAdmission() async {
        admitted.fulfill()
        await gate.wait()
    }

    func release() async { await gate.release() }
}

private final class CallbackCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class CoordinatorTranscriptReader: TranscriptDocumentReading, @unchecked Sendable {
    var snapshot: TranscriptDocumentSnapshot
    var readError: Error?
    private(set) var requests = 0
    init(snapshot: TranscriptDocumentSnapshot) { self.snapshot = snapshot }
    func readCanonical(in _: URL, allowLegacy _: Bool) throws -> TranscriptDocumentSnapshot {
        requests += 1
        if let readError { throw readError }
        return snapshot
    }
}

private final class CoordinatorRepository: OpenAICompatibleProviderManaging, @unchecked Sendable {
    var snapshotValue: OpenAICompatibleProviderSnapshot
    var snapshotError: Error?
    var snapshotEntered: XCTestExpectation?
    var snapshotFinished: XCTestExpectation?
    var snapshotRelease: DispatchSemaphore?
    init(snapshotValue: OpenAICompatibleProviderSnapshot) { self.snapshotValue = snapshotValue }
    func loadProfile() throws -> OpenAICompatibleProviderProfile? { snapshotValue.profile }
    func save(profile _: OpenAICompatibleProviderProfile, replacementAPIKey _: String?) throws {}
    func snapshot() throws -> OpenAICompatibleProviderSnapshot {
        snapshotEntered?.fulfill()
        snapshotRelease?.wait()
        snapshotFinished?.fulfill()
        if let snapshotError { throw snapshotError }
        return snapshotValue
    }
    func snapshot(overriding profile: OpenAICompatibleProviderProfile) throws -> OpenAICompatibleProviderSnapshot { try .validated(profile: profile, apiKey: snapshotValue.apiKey) }
    func hasAPIKey() throws -> Bool { snapshotValue.apiKey != nil }
    func removeAPIKey() throws {}
    func migrateLegacyIfNeeded(settingsURL _: URL) throws -> LegacyProviderMigrationOutcome { .notFound }
}

private final class CoordinatorAvailability: MeetingIntelligenceAvailabilityChecking, @unchecked Sendable {
    let value: MeetingIntelligenceAvailability
    private(set) var requests = 0
    init(value: MeetingIntelligenceAvailability) { self.value = value }
    func availability(for _: OpenAICompatibleProviderSnapshot) async -> MeetingIntelligenceAvailability { requests += 1; return value }
}

private final class CoordinatorGenerator: MeetingIntelligenceGenerating, @unchecked Sendable {
    private(set) var requests = 0
    func generate(transcript _: TranscriptDocumentSnapshot, snapshot _: OpenAICompatibleProviderSnapshot,
                  onProgress _: @escaping @Sendable (MeetingIntelligenceProgress) -> Void) async throws -> MeetingIntelligenceGeneratedContent {
        requests += 1
        return .init(title: "Generated", summary: "Summary")
    }
}

private final class SequencedCoordinatorGenerator: MeetingIntelligenceGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [MeetingIntelligenceGeneratedContent]

    init(contents: [MeetingIntelligenceGeneratedContent]) { self.contents = contents }

    func generate(transcript _: TranscriptDocumentSnapshot, snapshot _: OpenAICompatibleProviderSnapshot,
                  onProgress _: @escaping @Sendable (MeetingIntelligenceProgress) -> Void) async throws -> MeetingIntelligenceGeneratedContent {
        lock.withLock {
            precondition(!contents.isEmpty, "Missing generated test content")
            return contents.removeFirst()
        }
    }
}

private final class CoordinatorPublisher: MeetingIntelligencePublishing, @unchecked Sendable {
    private(set) var requests = 0
    private(set) var capturedModels: [String] = []
    func publish(_ request: MeetingIntelligencePublicationRequest) async throws -> MeetingIntelligencePublicationOutcome {
        requests += 1
        capturedModels.append(request.snapshot.profile.llmModel)
        return .init(artifact: .init(schemaVersion: 1, summary: request.content.summary, suggestedTitle: request.content.title,
                                     sourceTranscriptSHA256: request.sourceRevision.sha256, sourceTranscriptByteCount: request.sourceRevision.byteCount,
                                     model: request.snapshot.profile.llmModel, generatedAt: request.generatedAt, intent: request.intent),
                     titleWasApplied: false, titleWarning: nil)
    }
}

private final class CoordinatorArtifactStore: MeetingIntelligenceArtifactStoring, @unchecked Sendable {
    var loaded: MeetingIntelligenceArtifact?
    var loadError: Error?
    func load(in _: URL) throws -> MeetingIntelligenceArtifact? {
        if let loadError { throw loadError }
        return loaded
    }
    func stage(_: MeetingIntelligenceArtifact, in folder: URL) throws -> URL { folder }
    func promoteStaged(_: URL, in _: URL) throws {}
    func removeStaged(_: URL, in _: URL) throws {}
}

private final class CoordinatorMetadataStore: RecordingSessionMetadataStoring, @unchecked Sendable {
    var metadata = RecordingSessionMetadata()
    private(set) var saveCount = 0
    func load(in _: URL) -> RecordingSessionMetadata { metadata }
    func save(_ metadata: RecordingSessionMetadata, in _: URL) throws {
        saveCount += 1
        self.metadata = metadata
    }
}

private final class CoordinatorStateStore: MeetingIntelligenceStateStoring, @unchecked Sendable {
    var loaded: MeetingIntelligenceState?
    func load(in _: URL) throws -> MeetingIntelligenceState? { loaded }
    func save(_: MeetingIntelligenceState, in _: URL) throws {}
    func remove(in _: URL) throws {}
}

private final class BlockingStateStore: MeetingIntelligenceStateStoring, @unchecked Sendable {
    let entered: XCTestExpectation
    let release: DispatchSemaphore
    private(set) var saved: [MeetingIntelligenceState] = []
    private var shouldBlock = true
    init(entered: XCTestExpectation, release: DispatchSemaphore) { self.entered = entered; self.release = release }
    func load(in _: URL) throws -> MeetingIntelligenceState? { nil }
    func save(_ state: MeetingIntelligenceState, in _: URL) throws {
        if shouldBlock {
            shouldBlock = false
            entered.fulfill()
            release.wait()
        }
        saved.append(state)
    }
    func remove(in _: URL) throws {}
}

private final class RecordingStateStore: MeetingIntelligenceStateStoring, @unchecked Sendable {
    private(set) var saved: [MeetingIntelligenceState] = []
    func load(in _: URL) throws -> MeetingIntelligenceState? { nil }
    func save(_ state: MeetingIntelligenceState, in _: URL) throws { saved.append(state) }
    func remove(in _: URL) throws {}
}
