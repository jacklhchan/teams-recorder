import XCTest
@testable import RecorderApp

@MainActor
final class AppModelTranscriptionTests: XCTestCase {
    func testTranscriptionFeatureFactoryReceivesTheActiveRepositoryAndMutationGateOnce() throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let repository = RecordingProviderRepository()
        let preparer = ControlledPreparer(.immediate(.failure(TestError.failed)))
        let launcher = ControlledLauncher()
        var factoryCalls = 0
        weak var receivedRepository: AnyObject?
        weak var receivedGate: RecordingSessionMutationGate?

        let model = AppModel(
            providerRepository: repository,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            initialOutputFolder: fixture.root,
            transcriptionAudioPreparer: preparer,
            transcriptionProcessLauncher: launcher,
            transcriptionScriptURL: fixture.scriptURL,
            transcriptionFeatureFactory: { provider, configuredPreparer, service, gate in
                factoryCalls += 1
                receivedRepository = provider as AnyObject
                receivedGate = gate
                return TranscriptionFeatureModel(
                    coordinator: TranscriptionJobCoordinator(
                        providerRepository: provider,
                        audioPreparer: configuredPreparer,
                        service: service,
                        mutationGate: gate,
                        coordinatorInstanceID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
                    )
                )
            }
        )

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(receivedRepository === repository)
        XCTAssertNotNil(receivedGate)
        XCTAssertEqual(
            model.transcriptionFeature.publicationSourceID,
            UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
    }

    func testProgressPublishesOnlyTheFeatureAndCancellationUpdatesItImmediately() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher
        )
        var appPublications = 0
        let token = model.objectWillChange.sink { appPublications += 1 }
        defer { token.cancel() }

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        appPublications = 0
        process.emit("STATUS=Uploading transcription")
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(
            model.transcriptionFeature.presentation.transcriptionStatus,
            "Uploading transcription"
        )
        XCTAssertEqual(appPublications, 0)

        model.cancelTranscription()
        XCTAssertEqual(
            model.transcriptionFeature.presentation.transcriptionStatus,
            "Cancelling transcription..."
        )
    }

    func testRefreshKeepsTheLiveBlockingTranscriptionState() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let loaderStarted = expectation(description: "library load started")
        let releaseLoader = DispatchSemaphore(value: 0)
        defer { releaseLoader.signal() }
        let model = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher,
            recordingSessionLoader: { _ in
                loaderStarted.fulfill()
                releaseLoader.wait()
                return [fixture.session]
            }
        )

        model.transcribe(session: fixture.session)
        _ = await launcher.nextProcess()
        model.refreshSessions()
        await fulfillment(of: [loaderStarted], timeout: 1)
        releaseLoader.signal()
        _ = await eventually { model.sessions == [fixture.session] }

        XCTAssertEqual(
            model.transcriptionFeature.presentation
                .transcriptionStatesBySessionID[fixture.session.id]?.phase,
            .queued
        )
        model.cancelTranscription()
    }
    func testPreparedAudioIsPassedToLauncherAndCleanedAfterSuccess() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let cleanup = expectation(description: "prepared audio cleaned")
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: fixture.temporaryAudioURL
        ))), cleanup: cleanup)
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)
        let transcriptURL = fixture.session.folderURL.appendingPathComponent("transcript.txt")
        try "done".write(to: transcriptURL, atomically: true, encoding: .utf8)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        XCTAssertEqual(launcher.requests.last?.audioURL, fixture.temporaryAudioURL)
        XCTAssertEqual(launcher.requests.last?.folderURL, fixture.session.folderURL)
        process.complete(exitStatus: 0, output: "TRANSCRIPT_PATH=\(transcriptURL.path)")

        await fulfillment(of: [cleanup], timeout: 1)
        XCTAssertEqual(preparer.cleaned, [.init(audioURL: fixture.temporaryAudioURL, cleanupURL: fixture.temporaryAudioURL)])
        XCTAssertNil(model.transcribingSessionID)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .completed)
    }

    func testSavedProfileAllowsTranscriptionWhenAPIKeyStatusFails() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let repository = RecordingProviderRepository(
            profile: try OpenAICompatibleProviderProfile.validated(
                baseURLText: "https://api.example.com/v1",
                asrModel: "asr",
                llmModel: "llm",
                language: "en",
                prompt: ""
            ),
            apiKeyStatusError: TestError.failed
        )
        let model = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher,
            repository: repository,
            configureProvider: false
        )
        model.aiProviderSettingsModel.reload()

        guard model.aiProviderSettingsModel.hasSavedProfile else {
            XCTFail("A saved profile must remain available when API key status fails")
            return
        }
        model.transcribe(session: fixture.session)

        let process = await launcher.nextProcess()
        process.complete(exitStatus: 0)
        await waitForIdle(model)
    }

    func testCancelDuringPreparationCancelsWithoutLaunchingAndSettlesState() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let started = expectation(description: "prepare started")
        let preparer = ControlledPreparer(.suspended(started: started))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        await fulfillment(of: [started], timeout: 1)
        model.cancelTranscription()
        await waitForIdle(model)

        XCTAssertTrue(preparer.cancelled)
        XCTAssertTrue(launcher.requests.isEmpty)
        XCTAssertTrue(preparer.cleaned.isEmpty)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .cancelled)
    }

    func testReleasingModelDuringPreparationCancelsWithoutRetainCycle() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let started = expectation(description: "prepare started")
        let preparer = ControlledPreparer(.suspended(started: started))
        let launcher = ControlledLauncher()
        var model: AppModel? = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher
        )
        weak var weakModel = model

        model?.transcribe(session: fixture.session)
        await fulfillment(of: [started], timeout: 1)
        model = nil

        let released = await eventually { weakModel == nil }
        XCTAssertTrue(released, "The transcription task must not retain AppModel while preparation is suspended")
        if !released {
            weakModel?.cancelTranscription()
        }
        XCTAssertTrue(preparer.cancelled)
        XCTAssertTrue(launcher.requests.isEmpty)
    }

    func testCompleteDrainedOutputIsParsedBeforeAttemptClears() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)
        let transcriptURL = fixture.session.folderURL.appendingPathComponent("transcript.txt")
        try "done".write(to: transcriptURL, atomically: true, encoding: .utf8)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        process.complete(
            exitStatus: 0,
            output: "STATUS=Processing transcript\nTRANSCRIPT_PATH=\(transcriptURL.path)"
        )
        await waitForIdle(model)

        XCTAssertEqual(model.transcriptURLsBySessionID[fixture.session.id], transcriptURL)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .completed)
    }

    func testPublishedAndEditedTranscriptBecomeSearchableWithoutLibraryRefresh() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(
            .immediate(
                .success(
                    .init(
                        audioURL: fixture.temporaryAudioURL,
                        cleanupURL: nil
                    )
                )
            )
        )
        let launcher = ControlledLauncher()
        let offMainRebuilds = expectation(
            description: "affected search document rebuilt off main"
        )
        offMainRebuilds.expectedFulfillmentCount = 2
        let libraryMetadata = RecordingSessionMetadata(
            title: "Priority customer review",
            tags: ["favorite-search-tag"],
            isFavorite: true
        )
        let librarySession = RecordingSession(
            id: fixture.session.id,
            folderURL: fixture.session.folderURL,
            recordingURL: fixture.session.recordingURL,
            createdAt: fixture.session.createdAt,
            duration: fixture.session.duration,
            fileSize: fixture.session.fileSize,
            metadata: libraryMetadata,
            searchDocument: RecordingLibrarySearchDocument.load(
                folderURL: fixture.session.folderURL,
                displayName: "Priority customer review",
                createdAt: fixture.session.createdAt,
                metadata: libraryMetadata
            )
        )
        let model = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher,
            initialOutputFolder: fixture.root.deletingLastPathComponent(),
            recordingSearchDocumentLoader: { session in
                XCTAssertFalse(Thread.isMainThread)
                offMainRebuilds.fulfill()
                return RecordingLibrarySearchDocument.load(
                    folderURL: session.folderURL,
                    displayName: session.displayName,
                    createdAt: session.createdAt,
                    metadata: session.metadata
                )
            }
        )
        model.seedLibrarySessionsForTesting([librarySession])
        let canonicalLibrarySession = try XCTUnwrap(model.sessions.first)
        let publishedText = "first newly searchable phrase"
        let editedText = "replacement edited searchable phrase"
        let transcriptURL = canonicalLibrarySession.folderURL
            .appendingPathComponent("transcript.txt")
        try publishedText.write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(
            RecordingLibraryQuery(text: publishedText)
                .filter(model.sessions)
                .isEmpty
        )
        model.transcribe(session: canonicalLibrarySession)
        let process = await launcher.nextProcess()
        process.complete(
            exitStatus: 0,
            output: "TRANSCRIPT_PATH=\(transcriptURL.path)"
        )
        await waitForIdle(model)

        let publishedBecameSearchable = await eventually {
            RecordingLibraryQuery(text: publishedText)
                .filter(model.sessions)
                .map(\.id) == [canonicalLibrarySession.id]
        }
        XCTAssertTrue(
            publishedBecameSearchable,
            "Published transcript should update only the affected "
                + "in-memory search document."
        )
        let publishedSession = try XCTUnwrap(model.sessions.first)
        XCTAssertNotNil(
            RecordingLibraryQuery(text: publishedText)
                .transcriptSnippet(for: publishedSession)
        )
        XCTAssertEqual(
            RecordingLibraryQuery(
                text: "favorite-search-tag",
                favoritesOnly: true
            ).filter(model.sessions).map(\.id),
            [canonicalLibrarySession.id]
        )

        _ = await model.saveTranscript(editedText, for: publishedSession)

        let editedBecameSearchable = await eventually {
            RecordingLibraryQuery(text: editedText)
                .filter(model.sessions)
                .map(\.id) == [librarySession.id]
                && RecordingLibraryQuery(text: publishedText)
                    .filter(model.sessions)
                    .isEmpty
        }
        XCTAssertTrue(
            editedBecameSearchable,
            "Edited transcript should replace the affected search "
                + "document without a manual library refresh."
        )
        XCTAssertEqual(
            RecordingLibraryQuery(
                text: "Priority customer",
                favoritesOnly: true
            ).filter(model.sessions).map(\.id),
            [canonicalLibrarySession.id]
        )
        await fulfillment(of: [offMainRebuilds], timeout: 1)
    }

    func testLibraryRefreshInvalidatesStaleSearchDocumentRebuild() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let firstLoadStarted = expectation(
            description: "first search document load started"
        )
        let searchLoader = BlockingSearchDocumentLoader(
            firstLoadStarted: firstLoadStarted
        )
        defer { searchLoader.releaseFirstLoad() }
        let model = makeModel(
            fixture: fixture,
            preparer: ControlledPreparer(
                .immediate(.failure(TestError.failed))
            ),
            launcher: ControlledLauncher(),
            // A production refresh reads the transcript from disk. Returning
            // the immutable fixture session here made every refresh carry an
            // intentionally stale search document, which cannot happen with
            // RecordingSessionStore after the transcript write below.
            recordingSessionLoader: { _ in
                [fixture.session.replacingSearchDocument(
                    .load(
                        folderURL: fixture.session.folderURL,
                        displayName: fixture.session.displayName,
                        createdAt: fixture.session.createdAt,
                        metadata: fixture.session.metadata
                    )
                )]
            },
            recordingSearchDocumentLoader: { session in
                searchLoader.load(session)
            }
        )
        model.seedLibrarySessionsForTesting([fixture.session])
        let staleText = "stale transcript search term"
        let newestText = "newest transcript search term"

        let staleSave = Task {
            await model.saveTranscript(staleText, for: fixture.session)
        }
        await fulfillment(of: [firstLoadStarted], timeout: 1)
        model.refreshSessions()
        let newestSave = Task {
            await model.saveTranscript(newestText, for: fixture.session)
        }
        searchLoader.releaseFirstLoad()
        _ = await staleSave.value
        _ = await newestSave.value

        let newestDocumentWon = await eventually {
            RecordingLibraryQuery(text: newestText)
                .filter(model.sessions)
                .map(\.id) == [fixture.session.id]
                && RecordingLibraryQuery(text: staleText)
                    .filter(model.sessions)
                    .isEmpty
        }
        XCTAssertTrue(
            newestDocumentWon,
            "A search rebuild queued before refresh must not overwrite "
                + "a newer edited transcript."
        )
    }

    func testWorkspaceSwitchSuppressesQueuedManualTranscriptSearchRebuild() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let otherWorkspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: otherWorkspace,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: otherWorkspace) }
        let firstLoadStarted = expectation(
            description: "manual transcript search rebuild started"
        )
        let searchLoader = BlockingSearchDocumentLoader(
            firstLoadStarted: firstLoadStarted
        )
        defer { searchLoader.releaseFirstLoad() }
        let model = makeModel(
            fixture: fixture,
            preparer: ControlledPreparer(
                .immediate(.failure(TestError.failed))
            ),
            launcher: ControlledLauncher(),
            recordingSearchDocumentLoader: { session in
                searchLoader.load(session)
            }
        )
        model.seedLibrarySessionsForTesting([fixture.session])

        let save = Task {
            await model.saveTranscript(
                "old workspace searchable transcript",
                for: fixture.session
            )
        }
        await fulfillment(of: [firstLoadStarted], timeout: 1)
        model.setOutputFolder(otherWorkspace)
        searchLoader.releaseFirstLoad()
        _ = await save.value
        for _ in 0..<100 { await Task.yield() }

        XCTAssertFalse(
            model.sessions.contains(where: { $0.id == fixture.session.id })
        )
        XCTAssertTrue(
            RecordingLibraryQuery(text: "old workspace searchable transcript")
                .filter(model.sessions)
                .isEmpty
        )
    }

    func testCurrentArtifactResolutionReplacesCachedLegacyArtifactsWithCanonicalFiles() throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let model = makeModel(
            fixture: fixture,
            preparer: ControlledPreparer(.immediate(.failure(TestError.failed))),
            launcher: ControlledLauncher()
        )
        let legacyTranscript = fixture.session.folderURL.appendingPathComponent("transcript_qwen3_asr_1_7b_8bit_yue_trad.txt")
        let legacyLog = fixture.session.folderURL.appendingPathComponent("transcription_qwen_asr.log")
        try "legacy".write(to: legacyTranscript, atomically: true, encoding: .utf8)
        try Data().write(to: legacyLog)
        model.transcriptionFeature.setTranscriptURL(
            legacyTranscript,
            for: fixture.session.id
        )
        model.transcriptionFeature.setTranscriptLogURL(
            legacyLog,
            for: fixture.session.id
        )

        let canonicalTranscript = fixture.session.folderURL.appendingPathComponent("transcript.txt")
        let canonicalLog = fixture.session.folderURL.appendingPathComponent("transcription.log")
        try "canonical".write(to: canonicalTranscript, atomically: true, encoding: .utf8)
        try Data().write(to: canonicalLog)

        XCTAssertEqual(model.currentTranscriptURL(for: fixture.session), canonicalTranscript)
        XCTAssertEqual(model.currentTranscriptLogURL(for: fixture.session), canonicalLog)
        XCTAssertEqual(model.transcriptURLsBySessionID[fixture.session.id], canonicalTranscript)
        XCTAssertEqual(model.transcriptLogURLsBySessionID[fixture.session.id], canonicalLog)
    }

    func testCurrentArtifactResolutionClearsDeletedCachedFiles() throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let model = makeModel(
            fixture: fixture,
            preparer: ControlledPreparer(.immediate(.failure(TestError.failed))),
            launcher: ControlledLauncher()
        )
        let transcript = fixture.session.folderURL.appendingPathComponent("transcript.txt")
        let log = fixture.session.folderURL.appendingPathComponent("transcription.log")
        try "cached".write(to: transcript, atomically: true, encoding: .utf8)
        try Data().write(to: log)
        model.transcriptionFeature.setTranscriptURL(
            transcript,
            for: fixture.session.id
        )
        model.transcriptionFeature.setTranscriptLogURL(
            log,
            for: fixture.session.id
        )
        try FileManager.default.removeItem(at: transcript)
        try FileManager.default.removeItem(at: log)

        XCTAssertNil(model.currentTranscriptURL(for: fixture.session))
        XCTAssertNil(model.currentTranscriptLogURL(for: fixture.session))
        XCTAssertNil(model.transcriptURLsBySessionID[fixture.session.id])
        XCTAssertNil(model.transcriptLogURLsBySessionID[fixture.session.id])
    }

    func testFinalLegacyArtifactsYieldToSubsequentCanonicalResolution() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)
        let legacyTranscript = fixture.session.folderURL.appendingPathComponent("transcript_qwen3_asr_1_7b_8bit_yue_trad.txt")
        let legacyLog = fixture.session.folderURL.appendingPathComponent("transcription_qwen_asr.log")
        try "legacy".write(to: legacyTranscript, atomically: true, encoding: .utf8)
        try Data().write(to: legacyLog)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        process.complete(
            exitStatus: 0,
            output: "TRANSCRIPT_PATH=\(legacyTranscript.path)\nLOG_PATH=\(legacyLog.path)"
        )
        await waitForIdle(model)
        XCTAssertEqual(model.transcriptURLsBySessionID[fixture.session.id], legacyTranscript)
        XCTAssertEqual(model.transcriptLogURLsBySessionID[fixture.session.id], legacyLog)

        let canonicalTranscript = fixture.session.folderURL.appendingPathComponent("transcript.txt")
        let canonicalLog = fixture.session.folderURL.appendingPathComponent("transcription.log")
        try "canonical".write(to: canonicalTranscript, atomically: true, encoding: .utf8)
        try Data().write(to: canonicalLog)

        XCTAssertEqual(model.currentTranscriptURL(for: fixture.session), canonicalTranscript)
        XCTAssertEqual(model.currentTranscriptLogURL(for: fixture.session), canonicalLog)
    }

    func testProviderSnapshotIsCapturedBeforeAudioPreparation() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let started = expectation(description: "prepare started")
        let first = try makeSnapshot(asrModel: "first-model")
        let repository = try SnapshotProviderRepository(snapshot: first)
        let preparer = ControlledPreparer(.suspended(started: started))
        let launcher = ControlledLauncher()
        let model = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher,
            repository: repository,
            configureProvider: false
        )
        model.aiProviderSettingsModel.reload()

        model.transcribe(session: fixture.session)
        await fulfillment(of: [started])
        repository.snapshotValue = try makeSnapshot(asrModel: "second-model")
        preparer.resume(.success(.init(audioURL: fixture.temporaryAudioURL, cleanupURL: nil)))
        _ = await launcher.nextProcess()

        let payload = try JSONDecoder().decode(
            OpenAICompatibleTranscriptionLaunchPayload.self,
            from: try XCTUnwrap(launcher.requests.last?.configurationInput)
        )
        XCTAssertEqual(payload.asrModel, "first-model")
    }

    func testMissingProfileFailsBeforeAudioPreparation() throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let repository = try SnapshotProviderRepository(
            profile: try makeProfile(),
            snapshotError: ProviderRepositoryError.missingProfile
        )
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher,
            repository: repository,
            configureProvider: false
        )
        model.aiProviderSettingsModel.reload()

        model.transcribe(session: fixture.session)

        XCTAssertTrue(preparer.requests.isEmpty)
        XCTAssertTrue(model.lastTranscriptionDidFail)
        XCTAssertTrue(model.lastTranscriptionStatus.contains("Configure"))
    }

    func testTranscriptPathOutsideSessionFolderIsRejected() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        process.complete(exitStatus: 0, output: "TRANSCRIPT_PATH=/tmp/untrusted.txt")
        await waitForIdle(model)

        XCTAssertNil(model.transcriptURLsBySessionID[fixture.session.id])
        XCTAssertTrue(model.lastTranscriptionDidFail)
    }

    func testLogSymlinkEscapingSessionFolderIsRejected() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside.log")
        try Data().write(to: outside)
        let link = fixture.session.folderURL.appendingPathComponent("transcription.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        process.complete(exitStatus: 0, output: "LOG_PATH=\(link.path)")
        await waitForIdle(model)

        XCTAssertNil(model.transcriptLogURLsBySessionID[fixture.session.id])
        XCTAssertTrue(model.lastTranscriptionDidFail)
    }

    func testFinalResultLinesPublishTranscriptEvenWhenLiveCallbackIsDelayed() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let transcript = fixture.session.folderURL.appendingPathComponent("transcript.txt")
        try "done".write(to: transcript, atomically: true, encoding: .utf8)
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        process.complete(
            exitStatus: 0,
            output: "TRANSCRIPT_PATH=\(transcript.path)",
            deliverLiveCallbacks: false
        )
        await waitForIdle(model)

        XCTAssertEqual(model.transcriptURLsBySessionID[fixture.session.id], transcript)
        XCTAssertFalse(model.lastTranscriptionDidFail)
    }

    func testCancelAfterLaunchTerminatesOnceAndCleansPreparedAudio() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let cleanup = expectation(description: "cleanup after cancellation")
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: fixture.temporaryAudioURL
        ))), cleanup: cleanup)
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        model.cancelTranscription()
        await fulfillment(of: [cleanup], timeout: 1)

        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .cancelled)
    }

    func testCancelRejectsTranscriptPathArrivingInFinalProcessOutput() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let transcriptURL = fixture.root.appendingPathComponent("cancelled-transcript.txt")
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher(
            processTerminationOutput: "TRANSCRIPT_PATH=\(transcriptURL.path)"
        )
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        _ = await launcher.nextProcess()
        model.cancelTranscription()
        await waitForIdle(model)

        XCTAssertNil(model.transcriptURLsBySessionID[fixture.session.id])
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .cancelled)
    }

    func testPreparationFailureClearsActiveOwnerWithoutCleanup() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.failure(TestError.failed)))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        await waitForIdle(model)

        XCTAssertTrue(launcher.requests.isEmpty)
        XCTAssertTrue(preparer.cleaned.isEmpty)
        XCTAssertNil(model.transcribingSessionID)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .failed)
    }

    func testLaunchFailureCleansPreparedAudioAndClearsActiveOwner() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let cleanup = expectation(description: "cleanup after launch failure")
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: fixture.temporaryAudioURL
        ))), cleanup: cleanup)
        let launcher = ControlledLauncher(makeError: TestError.failed)
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        await fulfillment(of: [cleanup], timeout: 1)

        XCTAssertNil(model.transcribingSessionID)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .failed)
    }

    func testProcessRunFailureCleansPreparedAudioAndClearsActiveOwner() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let cleanup = expectation(description: "cleanup after process run failure")
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: fixture.temporaryAudioURL
        ))), cleanup: cleanup)
        let launcher = ControlledLauncher(processRunError: TestError.failed)
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        _ = await launcher.nextProcess()
        await fulfillment(of: [cleanup], timeout: 1)

        XCTAssertNil(model.transcribingSessionID)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .failed)
        XCTAssertTrue(model.lastTranscriptionStatus.hasPrefix("Transcription launch failed"))
    }

    func testStaleOutputAndCompletionCannotMutateNewerAttempt() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: fixture.temporaryAudioURL
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        let first = await launcher.nextProcess()
        first.complete(exitStatus: 0)
        await waitForIdle(model)

        model.transcribe(session: fixture.session)
        let second = await launcher.nextProcess()
        first.emit("STATUS=old output\nTRANSCRIPT_PATH=/tmp/old.txt\n")
        first.complete(exitStatus: 9)
        await Task.yield()

        XCTAssertEqual(model.transcribingSessionID, fixture.session.id)
        XCTAssertNotEqual(model.transcriptionStatus, "old output")
        XCTAssertNil(model.transcriptURLsBySessionID[fixture.session.id])
        second.complete(exitStatus: 0)
        await waitForIdle(model)
    }

    func testNonzeroExitPersistsFailure() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: fixture.temporaryAudioURL
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        process.complete(exitStatus: 7)
        await waitForIdle(model)

        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .failed)
        XCTAssertTrue(model.lastTranscriptionStatus.contains("exit code 7"))
    }

    func testProviderErrorContainingSnapshotAPIKeyIsNotPublishedOrPersisted() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let secret = "exact-private-api-key"
        let repository = try SnapshotProviderRepository(
            snapshot: try .validated(profile: makeProfile(), apiKey: secret)
        )
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher,
            repository: repository,
            configureProvider: false
        )
        model.aiProviderSettingsModel.reload()

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        process.complete(
            exitStatus: 7,
            output: "ERROR=Provider rejected \(secret) while uploading"
        )
        await waitForIdle(model)

        let persisted = try XCTUnwrap(
            try TranscriptionStateStore.load(in: fixture.session.folderURL)
        )
        XCTAssertFalse(model.transcriptionStatus.contains(secret))
        XCTAssertFalse(model.lastTranscriptionStatus.contains(secret))
        XCTAssertFalse(model.statusMessage.contains(secret))
        XCTAssertFalse(persisted.message.contains(secret))
    }

    func testLiveProviderErrorContainingSnapshotAPIKeyIsNotPublishedOrPersisted() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let secret = "exact-live-private-api-key"
        let repository = try SnapshotProviderRepository(
            snapshot: try .validated(profile: makeProfile(), apiKey: secret)
        )
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher,
            repository: repository,
            configureProvider: false
        )
        model.aiProviderSettingsModel.reload()

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        defer { process.complete(exitStatus: -15) }
        process.emit("ERROR=Provider rejected \(secret) while uploading")
        await Task.yield()
        await Task.yield()

        let persisted = try XCTUnwrap(
            try TranscriptionStateStore.load(in: fixture.session.folderURL)
        )
        XCTAssertFalse(model.transcriptionStatus.contains(secret))
        XCTAssertFalse(model.lastTranscriptionStatus.contains(secret))
        XCTAssertFalse(model.statusMessage.contains(secret))
        XCTAssertFalse(persisted.message.contains(secret))
    }

    private func makeModel(
        fixture: TranscriptionFixture,
        preparer: ControlledPreparer,
        launcher: ControlledLauncher,
        repository: any OpenAICompatibleProviderManaging = RecordingProviderRepository(),
        configureProvider: Bool = true,
        initialOutputFolder: URL? = nil,
        recordingSessionLoader: @escaping @Sendable (
            URL
        ) -> [RecordingSession] = {
            RecordingSessionStore.load(from: $0)
        },
        recordingSearchDocumentLoader: @escaping @Sendable (
            RecordingSession
        ) -> RecordingLibrarySearchDocument = { session in
            RecordingLibrarySearchDocument.load(
                folderURL: session.folderURL,
                displayName: session.displayName,
                createdAt: session.createdAt,
                metadata: session.metadata
            )
        }
    ) -> AppModel {
        let model = AppModel(
            providerRepository: repository,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            initialOutputFolder: initialOutputFolder ?? fixture.root,
            recordingSessionLoader: recordingSessionLoader,
            recordingSearchDocumentLoader:
                recordingSearchDocumentLoader,
            transcriptionAudioPreparer: preparer,
            transcriptionProcessLauncher: launcher,
            transcriptionScriptURL: fixture.scriptURL
        )
        if configureProvider {
            model.aiProviderSettingsModel.baseURLText = "https://api.example.com/v1"
            model.aiProviderSettingsModel.asrModel = "asr"
            model.aiProviderSettingsModel.llmModel = "llm"
            model.aiProviderSettingsModel.selectedLanguage = .cantonese
            model.aiProviderSettingsModel.save()
        }
        return model
    }

    private func waitForIdle(
        _ model: AppModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard await eventually({ model.transcribingSessionID == nil }) else {
            XCTFail("Transcription did not become idle", file: file, line: line)
            return
        }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func makeSnapshot(asrModel: String) throws -> OpenAICompatibleProviderSnapshot {
        try .validated(profile: makeProfile(asrModel: asrModel), apiKey: "saved")
    }

    private func makeProfile(asrModel: String = "asr") throws -> OpenAICompatibleProviderProfile {
        try OpenAICompatibleProviderProfile.validated(
            baseURLText: "https://api.example.com/v1",
            asrModel: asrModel,
            llmModel: "llm",
            language: "en",
            prompt: ""
        )
    }
}

private final class BlockingSearchDocumentLoader:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let firstLoadStarted: XCTestExpectation
    private let firstLoadGate = DispatchSemaphore(value: 0)
    private var loadCount = 0

    init(firstLoadStarted: XCTestExpectation) {
        self.firstLoadStarted = firstLoadStarted
    }

    func load(
        _ session: RecordingSession
    ) -> RecordingLibrarySearchDocument {
        let document = RecordingLibrarySearchDocument.load(
            folderURL: session.folderURL,
            displayName: session.displayName,
            createdAt: session.createdAt,
            metadata: session.metadata
        )
        let isFirstLoad = lock.withLock {
            loadCount += 1
            return loadCount == 1
        }
        if isFirstLoad {
            firstLoadStarted.fulfill()
            firstLoadGate.wait()
        }
        return document
    }

    func releaseFirstLoad() {
        firstLoadGate.signal()
    }
}

private enum TestError: Error { case failed }

private final class ControlledPreparer: TranscriptionAudioPreparing, @unchecked Sendable {
    enum Mode {
        case immediate(Result<PreparedTranscriptionAudio, Error>)
        case suspended(started: XCTestExpectation)
    }

    private let lock = NSLock()
    private let mode: Mode
    private let cleanupExpectation: XCTestExpectation?
    private var continuation: CheckedContinuation<PreparedTranscriptionAudio, Error>?
    private(set) var cancelled = false
    private(set) var cleaned: [PreparedTranscriptionAudio] = []
    private(set) var requests: [RecordingSession] = []

    init(_ mode: Mode, cleanup: XCTestExpectation? = nil) {
        self.mode = mode
        cleanupExpectation = cleanup
    }

    func prepare(for session: RecordingSession) async throws -> PreparedTranscriptionAudio {
        lock.withLock {
            requests.append(session)
        }
        switch mode {
        case .immediate(let result):
            return try result.get()
        case .suspended(let started):
            started.fulfill()
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock {
                        self.continuation = continuation
                    }
                }
            }, onCancel: { [weak self] in
                self?.cancelPreparation()
            })
        }
    }

    func cleanup(_ prepared: PreparedTranscriptionAudio) {
        lock.withLock {
            cleaned.append(prepared)
        }
        cleanupExpectation?.fulfill()
    }

    private func cancelPreparation() {
        let continuation: CheckedContinuation<PreparedTranscriptionAudio, Error>? = lock.withLock {
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func resume(_ result: Result<PreparedTranscriptionAudio, Error>) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private final class ControlledLauncher: TranscriptionProcessLaunching {
    private let lock = NSLock()
    private let makeError: Error?
    private let processRunError: Error?
    private let processTerminationOutput: String
    private var processContinuation: CheckedContinuation<ControlledProcess, Never>?
    private var pendingProcesses: [ControlledProcess] = []
    private(set) var requests: [TranscriptionProcessRequest] = []

    init(
        makeError: Error? = nil,
        processRunError: Error? = nil,
        processTerminationOutput: String = ""
    ) {
        self.makeError = makeError
        self.processRunError = processRunError
        self.processTerminationOutput = processTerminationOutput
    }

    func makeProcess(
        request: TranscriptionProcessRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws -> any TranscriptionProcessing {
        if let makeError { throw makeError }
        let process = ControlledProcess(
            onOutput: onOutput,
            runError: processRunError,
            terminationOutput: processTerminationOutput
        )
        let continuation: CheckedContinuation<ControlledProcess, Never>? = lock.withLock {
            requests.append(request)
            let continuation = processContinuation
            processContinuation = nil
            if continuation == nil {
                pendingProcesses.append(process)
            }
            return continuation
        }
        continuation?.resume(returning: process)
        return process
    }

    func nextProcess() async -> ControlledProcess {
        await withCheckedContinuation { continuation in
            let pending: ControlledProcess? = lock.withLock {
                if !pendingProcesses.isEmpty {
                    return pendingProcesses.removeFirst()
                }
                precondition(processContinuation == nil, "Only one nextProcess waiter is supported")
                processContinuation = continuation
                return nil
            }
            if let pending {
                continuation.resume(returning: pending)
            }
        }
    }
}

private final class ControlledProcess: TranscriptionProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private let onOutput: @Sendable (String) -> Void
    private let runError: Error?
    private let terminationOutput: String
    private var exitContinuation: CheckedContinuation<TranscriptionProcessResult, Never>?
    private var completedResult: TranscriptionProcessResult?
    private(set) var terminateCount = 0

    init(
        onOutput: @escaping @Sendable (String) -> Void,
        runError: Error? = nil,
        terminationOutput: String = ""
    ) {
        self.onOutput = onOutput
        self.runError = runError
        self.terminationOutput = terminationOutput
    }

    func run() throws {
        if let runError {
            throw runError
        }
    }

    func waitForExit() async -> TranscriptionProcessResult {
        await withCheckedContinuation { continuation in
            let result: TranscriptionProcessResult? = lock.withLock {
                if let completedResult {
                    return completedResult
                }
                exitContinuation = continuation
                return nil
            }
            if let result {
                continuation.resume(returning: result)
            }
        }
    }

    func terminate() {
        lock.withLock {
            terminateCount += 1
        }
        complete(exitStatus: -15, output: terminationOutput)
    }

    func emit(_ output: String) {
        onOutput(output)
    }

    func complete(
        exitStatus: Int32,
        output: String = "",
        deliverLiveCallbacks: Bool = true
    ) {
        let protocolLines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter {
                $0.hasPrefix("STATUS=")
                    || $0.hasPrefix("TRANSCRIPT_PATH=")
                    || $0.hasPrefix("LOG_PATH=")
                    || $0.hasPrefix("ERROR=")
            }
        let completion: (
            TranscriptionProcessResult,
            CheckedContinuation<TranscriptionProcessResult, Never>?
        )? = lock.withLock {
            guard completedResult == nil else { return nil }
            let result = TranscriptionProcessResult(
                exitStatus: exitStatus,
                output: output,
                protocolLines: protocolLines
            )
            completedResult = result
            let continuation = exitContinuation
            exitContinuation = nil
            return (result, continuation)
        }
        if let completion {
            if deliverLiveCallbacks {
                for line in protocolLines {
                    onOutput(line)
                }
            }
            completion.1?.resume(returning: completion.0)
        }
    }
}

private final class SnapshotProviderRepository: OpenAICompatibleProviderManaging {
    var snapshotValue: OpenAICompatibleProviderSnapshot
    private let profile: OpenAICompatibleProviderProfile?
    private let snapshotError: Error?

    init(
        snapshot: OpenAICompatibleProviderSnapshot? = nil,
        profile: OpenAICompatibleProviderProfile? = nil,
        snapshotError: Error? = nil
    ) throws {
        if let snapshot {
            snapshotValue = snapshot
        } else if let profile {
            snapshotValue = try .validated(profile: profile, apiKey: nil)
        } else {
            throw ProviderRepositoryError.missingProfile
        }
        self.profile = profile ?? snapshot?.profile
        self.snapshotError = snapshotError
    }

    func loadProfile() throws -> OpenAICompatibleProviderProfile? { profile }
    func save(profile: OpenAICompatibleProviderProfile, replacementAPIKey: String?) throws {}
    func snapshot() throws -> OpenAICompatibleProviderSnapshot {
        if let snapshotError { throw snapshotError }
        return snapshotValue
    }
    func snapshot(overriding profile: OpenAICompatibleProviderProfile) throws -> OpenAICompatibleProviderSnapshot {
        try .validated(profile: profile, apiKey: snapshotValue.apiKey)
    }
    func hasAPIKey() throws -> Bool { snapshotValue.apiKey != nil }
    func removeAPIKey() throws {}
    func migrateLegacyIfNeeded(settingsURL: URL) throws -> LegacyProviderMigrationOutcome { .notFound }
}

private struct TranscriptionFixture {
    let root: URL
    let session: RecordingSession
    let temporaryAudioURL: URL
    let scriptURL: URL

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scriptURL = root.appendingPathComponent("transcribe-qwen-asr.sh")
        FileManager.default.createFile(atPath: scriptURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return .init(
            root: root,
            session: .init(
                id: root,
                folderURL: root,
                recordingURL: root.appendingPathComponent("recording.mp4"),
                createdAt: .now,
                duration: 0,
                fileSize: 0,
                metadata: .init()
            ),
            temporaryAudioURL: root.appendingPathComponent("prepared.m4a"),
            scriptURL: scriptURL
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
