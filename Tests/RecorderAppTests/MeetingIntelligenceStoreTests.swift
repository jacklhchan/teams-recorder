import Foundation
import XCTest
@testable import RecorderApp

final class MeetingIntelligenceStoreTests: XCTestCase {
    private let gate = RecordingSessionMutationGate()

    func testStagesAndPromotesValidV1Artifact() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let store = MeetingIntelligenceArtifactStore(mutationGate: gate)
        let artifact = fixture.artifact(summary: "Customer migration")

        let staged = try store.stage(artifact, in: fixture.folder)
        XCTAssertTrue(staged.lastPathComponent.hasPrefix(".meeting-intelligence-stage-"))
        XCTAssertEqual(try store.load(in: fixture.folder), nil)

        try store.promoteStaged(staged, in: fixture.folder)
        XCTAssertEqual(try store.load(in: fixture.folder), artifact)
    }

    func testRemoveStagedUsesIdentityCheckedCleanup() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let store = MeetingIntelligenceArtifactStore(mutationGate: gate)
        let staged = try store.stage(fixture.artifact(), in: fixture.folder)

        try store.removeStaged(staged, in: fixture.folder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertNil(try store.load(in: fixture.folder))
    }

    func testRemoveStagedRejectsReplacementInsteadOfDeletingIt() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let replacement = Data("replacement".utf8)
        let access = ScriptedFileAccess(removeHook: { folder, name in
            let url = folder.appendingPathComponent(name)
            try FileManager.default.removeItem(at: url)
            try replacement.write(to: url)
        })
        let store = MeetingIntelligenceArtifactStore(mutationGate: gate, fileAccess: access)
        let staged = try store.stage(fixture.artifact(), in: fixture.folder)

        XCTAssertThrowsError(try store.removeStaged(staged, in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: staged), replacement)
        XCTAssertEqual(access.removeCalls, 0)
    }

    func testV1ArtifactIgnoresUnknownFields() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let data = Data(#"""
        {"schemaVersion":1,"summary":"Summary","suggestedTitle":"Title","sourceTranscriptSHA256":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceTranscriptByteCount":3,"model":"model","generatedAt":"2026-07-31T00:00:00Z","intent":"generate","future":{"nested":[1,true]}}
        """#.utf8)
        try data.write(to: fixture.artifactURL)

        XCTAssertEqual(
            try MeetingIntelligenceArtifactStore(mutationGate: gate).load(in: fixture.folder)?.summary,
            "Summary"
        )
    }

    func testFutureArtifactIsPreservedAndNotDecodedAsCurrent() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let future = Data(#"{"schemaVersion":2,"summary":"future"}"#.utf8)
        try future.write(to: fixture.artifactURL)

        XCTAssertThrowsError(
            try MeetingIntelligenceArtifactStore(mutationGate: gate).load(in: fixture.folder)
        ) {
            XCTAssertEqual(
                $0 as? MeetingIntelligenceStoreError,
                .unsupportedSchemaVersion(2)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.artifactURL), future)
    }

    func testRejectsMalformedAndOversizedArtifactsWithoutReplacingExistingResult() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let original = try fixture.writeExistingArtifact()
        try Data("not json".utf8).write(to: fixture.artifactURL)

        XCTAssertThrowsError(try MeetingIntelligenceArtifactStore(mutationGate: gate).load(in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .malformed)
        }

        try original.write(to: fixture.artifactURL)
        let oversized = Data(repeating: 0x61, count: MeetingIntelligenceArtifactStore.maximumBytes + 1)
        try oversized.write(to: fixture.artifactURL)
        XCTAssertThrowsError(try MeetingIntelligenceArtifactStore(mutationGate: gate).load(in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .tooLarge)
        }
    }

    func testRejectsSymlinkAndDirectoryArtifacts() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let outside = fixture.root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.artifactURL,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try MeetingIntelligenceArtifactStore(mutationGate: gate).load(in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .unsafeFile)
        }

        try FileManager.default.removeItem(at: fixture.artifactURL)
        try FileManager.default.createDirectory(at: fixture.artifactURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try MeetingIntelligenceArtifactStore(mutationGate: gate).load(in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .unsafeFile)
        }
    }

    func testFailedPromotionPreservesExistingArtifactBytes() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let original = try fixture.writeExistingArtifact()
        let missingStage = fixture.folder.appendingPathComponent(".meeting-intelligence-stage-missing")

        XCTAssertThrowsError(
            try MeetingIntelligenceArtifactStore(mutationGate: gate).promoteStaged(
                missingStage,
                in: fixture.folder
            )
        )
        XCTAssertEqual(try Data(contentsOf: fixture.artifactURL), original)
    }

    func testPromotionRejectsFutureDestinationWithoutChangingBytes() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let future = Data(#"{"schemaVersion":2,"summary":"future"}"#.utf8)
        try future.write(to: fixture.artifactURL)
        let staged = try MeetingIntelligenceArtifactStore(mutationGate: gate).stage(fixture.artifact(), in: fixture.folder)

        XCTAssertThrowsError(try MeetingIntelligenceArtifactStore(mutationGate: gate).promoteStaged(staged, in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .unsupportedSchemaVersion(2))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.artifactURL), future)
    }

    func testActiveStateLoadsAsInterruptedAndTerminalStateIsRetained() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let store = MeetingIntelligenceStateStore(mutationGate: gate)
        let started = Date(timeIntervalSince1970: 1_785_427_200)
        try store.save(
            MeetingIntelligenceState(
                schemaVersion: 1,
                phase: .generating,
                message: "Generating",
                sourceTranscriptSHA256: "sha256:abc",
                startedAt: started,
                finishedAt: nil
            ),
            in: fixture.folder
        )

        let interrupted = try XCTUnwrap(try store.load(in: fixture.folder))
        XCTAssertEqual(interrupted.phase, .interrupted)
        XCTAssertEqual(interrupted.startedAt, started)
        XCTAssertNotNil(interrupted.finishedAt)

        try store.save(
            .init(
                schemaVersion: 1,
                phase: .completed,
                message: "Completed",
                sourceTranscriptSHA256: nil,
                startedAt: started,
                finishedAt: started.addingTimeInterval(1)
            ),
            in: fixture.folder
        )
        XCTAssertEqual(try store.load(in: fixture.folder)?.phase, .completed)
        try store.remove(in: fixture.folder)
        XCTAssertNil(try store.load(in: fixture.folder))
    }

    func testStateSaveAndRemoveRejectFutureDestinationWithoutChangingBytes() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let url = fixture.folder.appendingPathComponent(MeetingIntelligenceStateStore.fileName)
        let future = Data(#"{"schemaVersion":2,"phase":"completed"}"#.utf8)
        try future.write(to: url)
        let state = MeetingIntelligenceState(
            schemaVersion: 1,
            phase: .completed,
            message: "Completed",
            sourceTranscriptSHA256: nil,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: nil
        )

        XCTAssertThrowsError(try MeetingIntelligenceStateStore(mutationGate: gate).save(state, in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .unsupportedSchemaVersion(2))
        }
        XCTAssertEqual(try Data(contentsOf: url), future)
        XCTAssertThrowsError(try MeetingIntelligenceStateStore(mutationGate: gate).remove(in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .unsupportedSchemaVersion(2))
        }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testPromotionRejectsStagedIdentityChangeWithoutReplacingArtifact() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let original = try fixture.writeExistingArtifact()
        let access = ScriptedFileAccess { folder, stagedName, _ in
            let url = folder.appendingPathComponent(stagedName)
            try FileManager.default.removeItem(at: url)
            try Data("replacement".utf8).write(to: url)
        }
        let store = MeetingIntelligenceArtifactStore(mutationGate: gate, fileAccess: access)
        let staged = try store.stage(fixture.artifact(summary: "replacement"), in: fixture.folder)

        XCTAssertThrowsError(try store.promoteStaged(staged, in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.artifactURL), original)
        XCTAssertEqual(access.renameCalls, 0)
    }

    func testPromotionRejectsDestinationIdentityChangeWithoutReplacingArtifact() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        _ = try fixture.writeExistingArtifact()
        let access = ScriptedFileAccess { folder, _, destinationName in
            let url = folder.appendingPathComponent(destinationName)
            try FileManager.default.removeItem(at: url)
            try Data("replacement".utf8).write(to: url)
        }
        let store = MeetingIntelligenceArtifactStore(mutationGate: gate, fileAccess: access)
        let staged = try store.stage(fixture.artifact(summary: "replacement"), in: fixture.folder)

        XCTAssertThrowsError(try store.promoteStaged(staged, in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.artifactURL), Data("replacement".utf8))
        XCTAssertEqual(access.renameCalls, 0)
    }

    func testInjectedRenameFailurePreservesArtifactAndStateBytes() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let artifactBytes = try fixture.writeExistingArtifact()
        let stateURL = fixture.folder.appendingPathComponent(MeetingIntelligenceStateStore.fileName)
        let stateBytes = try fixture.stateData().writeAndReturn(to: stateURL)
        let access = ScriptedFileAccess(renameError: .unsafeFile)
        let artifactStore = MeetingIntelligenceArtifactStore(mutationGate: gate, fileAccess: access)
        let stateStore = MeetingIntelligenceStateStore(mutationGate: gate, fileAccess: access)
        let staged = try artifactStore.stage(fixture.artifact(summary: "replacement"), in: fixture.folder)

        XCTAssertThrowsError(try artifactStore.promoteStaged(staged, in: fixture.folder))
        XCTAssertThrowsError(try stateStore.save(fixture.state(), in: fixture.folder))
        XCTAssertEqual(try Data(contentsOf: fixture.artifactURL), artifactBytes)
        XCTAssertEqual(try Data(contentsOf: stateURL), stateBytes)
    }

    func testFailedStatePromotionCleanupPreservesReplacedStage() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let replacement = Data("replacement-stage".utf8)
        let access = ScriptedFileAccess(
            renameError: .unsafeFile,
            removeHook: { folder, name in
                let url = folder.appendingPathComponent(name)
                try FileManager.default.removeItem(at: url)
                try replacement.write(to: url)
            }
        )
        let store = MeetingIntelligenceStateStore(mutationGate: gate, fileAccess: access)

        XCTAssertThrowsError(try store.save(fixture.state(), in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .unsafeFile)
        }
        let stage = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: fixture.folder, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".meeting-intelligence-state-stage-") }
        )
        XCTAssertEqual(try Data(contentsOf: stage), replacement)
        XCTAssertEqual(access.removeCalls, 0)
    }

    func testStateRemoveRejectsIdentityChangeWithoutUnlinkingReplacement() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let stateURL = fixture.folder.appendingPathComponent(MeetingIntelligenceStateStore.fileName)
        try fixture.stateData().write(to: stateURL)
        let access = ScriptedFileAccess(removeHook: { folder, name in
            let url = folder.appendingPathComponent(name)
            try FileManager.default.removeItem(at: url)
            try Data("replacement".utf8).write(to: url)
        })
        let store = MeetingIntelligenceStateStore(mutationGate: gate, fileAccess: access)

        XCTAssertThrowsError(try store.remove(in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), Data("replacement".utf8))
        XCTAssertEqual(access.removeCalls, 0)
    }

    func testArtifactAndStateHardLinksAreRejected() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let artifactSource = fixture.root.appendingPathComponent("artifact-source")
        try fixture.writeExistingArtifact().write(to: artifactSource)
        try FileManager.default.removeItem(at: fixture.artifactURL)
        try FileManager.default.linkItem(at: artifactSource, to: fixture.artifactURL)
        XCTAssertThrowsError(try MeetingIntelligenceArtifactStore(mutationGate: gate).load(in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .unsafeFile)
        }

        let stateURL = fixture.folder.appendingPathComponent(MeetingIntelligenceStateStore.fileName)
        let stateSource = fixture.root.appendingPathComponent("state-source")
        try fixture.stateData().write(to: stateSource)
        try FileManager.default.linkItem(at: stateSource, to: stateURL)
        let store = MeetingIntelligenceStateStore(mutationGate: gate)
        XCTAssertThrowsError(try store.save(fixture.state(), in: fixture.folder))
        XCTAssertThrowsError(try store.remove(in: fixture.folder))
    }

    func testStateSaveAndRemoveRejectSymlinkAndDirectory() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let stateURL = fixture.folder.appendingPathComponent(MeetingIntelligenceStateStore.fileName)
        let outside = fixture.root.appendingPathComponent("outside-state")
        try fixture.stateData().write(to: outside)
        try FileManager.default.createSymbolicLink(at: stateURL, withDestinationURL: outside)
        let store = MeetingIntelligenceStateStore(mutationGate: gate)
        XCTAssertThrowsError(try store.save(fixture.state(), in: fixture.folder))
        XCTAssertThrowsError(try store.remove(in: fixture.folder))

        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.save(fixture.state(), in: fixture.folder))
        XCTAssertThrowsError(try store.remove(in: fixture.folder))
    }

    func testExactReadBoundariesAcceptMaximumAndRejectMaximumPlusOne() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let artifactPrefix = Data(#"{"schemaVersion":1,"summary":"Summary","suggestedTitle":"Title","sourceTranscriptSHA256":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceTranscriptByteCount":0,"model":"model","generatedAt":"2026-01-01T00:00:00Z","intent":"generate"}"#.utf8)
        try fixture.writePadded(artifactPrefix, to: fixture.artifactURL, count: MeetingIntelligenceArtifactStore.maximumBytes)
        XCTAssertNotNil(try MeetingIntelligenceArtifactStore(mutationGate: gate).load(in: fixture.folder))
        try fixture.writePadded(artifactPrefix, to: fixture.artifactURL, count: MeetingIntelligenceArtifactStore.maximumBytes + 1)
        XCTAssertThrowsError(try MeetingIntelligenceArtifactStore(mutationGate: gate).load(in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .tooLarge)
        }

        let stateURL = fixture.folder.appendingPathComponent(MeetingIntelligenceStateStore.fileName)
        let statePrefix = fixture.stateData()
        try fixture.writePadded(statePrefix, to: stateURL, count: MeetingIntelligenceStateStore.maximumBytes)
        XCTAssertNotNil(try MeetingIntelligenceStateStore(mutationGate: gate).load(in: fixture.folder))
        try fixture.writePadded(statePrefix, to: stateURL, count: MeetingIntelligenceStateStore.maximumBytes + 1)
        XCTAssertThrowsError(try MeetingIntelligenceStateStore(mutationGate: gate).load(in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .tooLarge)
        }
    }

    func testOversizedArtifactStagePreservesExistingArtifact() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let original = try fixture.writeExistingArtifact()
        let oversized = fixture.artifact(summary: String(repeating: "x", count: MeetingIntelligenceArtifactStore.maximumBytes))

        XCTAssertThrowsError(try MeetingIntelligenceArtifactStore(mutationGate: gate).stage(oversized, in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .malformed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.artifactURL), original)
    }

    func testArtifactStageAndLoadEnforceCurrentSchemaConstraints() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let store = MeetingIntelligenceArtifactStore(mutationGate: gate)
        let base = fixture.artifact()
        let invalid: [(String, MeetingIntelligenceArtifact)] = [
            ("blank summary", fixture.artifact(summary: " \n\t ")),
            ("large summary", fixture.artifact(summary: String(repeating: "a", count: MeetingIntelligenceArtifactValidator.maximumSummaryBytes + 1))),
            ("summary controls", fixture.artifact(summary: "bad\u{202E}")),
            ("date title", fixture.artifact(title: "2026-07-31")),
            ("path title", fixture.artifact(title: "folder/name")),
            ("title controls", fixture.artifact(title: "bad\u{200B}title")),
            ("large title", fixture.artifact(title: String(repeating: "t", count: MeetingIntelligenceArtifactValidator.maximumTitleGraphemes + 1))),
            ("bad hash", fixture.artifact(hash: "sha256:ABC")),
            ("negative transcript bytes", fixture.artifact(byteCount: -1)),
            ("too many transcript bytes", fixture.artifact(byteCount: MeetingIntelligenceArtifactValidator.maximumTranscriptBytes + 1)),
            ("blank model", fixture.artifact(model: " ")),
            ("large model", fixture.artifact(model: String(repeating: "m", count: MeetingIntelligenceArtifactValidator.maximumModelBytes + 1))),
            ("model controls", fixture.artifact(model: "model\u{202E}"))
        ]

        XCTAssertTrue(MeetingIntelligenceArtifactValidator.isValid(base))
        for (name, artifact) in invalid {
            XCTAssertThrowsError(try store.stage(artifact, in: fixture.folder), name) {
                XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .malformed)
            }
            let data = try JSONEncoder.meetingIntelligence.encode(artifact)
            try data.write(to: fixture.artifactURL)
            XCTAssertThrowsError(try store.load(in: fixture.folder), name) {
                XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .malformed)
            }
            try FileManager.default.removeItem(at: fixture.artifactURL)
        }

        let nonFiniteDate = fixture.artifact(generatedAt: Date(timeIntervalSinceReferenceDate: .infinity))
        XCTAssertThrowsError(try store.stage(nonFiniteDate, in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .malformed)
        }

        for raw in [
            #"{"schemaVersion":1,"summary":"Summary","suggestedTitle":"Title","sourceTranscriptSHA256":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceTranscriptByteCount":3,"model":"model","generatedAt":"not-a-date","intent":"generate"}"#,
            #"{"schemaVersion":1,"summary":"Summary","suggestedTitle":"Title","sourceTranscriptSHA256":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceTranscriptByteCount":3,"model":"model","generatedAt":"2026-07-31T00:00:00Z","intent":"unexpected"}"#
        ] {
            try Data(raw.utf8).write(to: fixture.artifactURL)
            XCTAssertThrowsError(try store.load(in: fixture.folder)) {
                XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .malformed)
            }
            try FileManager.default.removeItem(at: fixture.artifactURL)
        }

        let unsupported = MeetingIntelligenceArtifact(
            schemaVersion: 2,
            summary: base.summary,
            suggestedTitle: base.suggestedTitle,
            sourceTranscriptSHA256: base.sourceTranscriptSHA256,
            sourceTranscriptByteCount: base.sourceTranscriptByteCount,
            model: base.model,
            generatedAt: base.generatedAt,
            intent: base.intent
        )
        XCTAssertThrowsError(try store.stage(unsupported, in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .unsupportedSchemaVersion(2))
        }
    }

    func testArtifactValidExactEncodingRetainsUnknownV1FieldsAndBoundaryValues() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let artifact = fixture.artifact(
            summary: "line one\nline\ttwo",
            title: String(repeating: "a", count: MeetingIntelligenceArtifactValidator.maximumTitleGraphemes),
            byteCount: MeetingIntelligenceArtifactValidator.maximumTranscriptBytes,
            model: String(repeating: "m", count: MeetingIntelligenceArtifactValidator.maximumModelBytes)
        )
        let store = MeetingIntelligenceArtifactStore(mutationGate: gate)
        let staged = try store.stage(artifact, in: fixture.folder)
        try store.promoteStaged(staged, in: fixture.folder)
        XCTAssertEqual(try store.load(in: fixture.folder), artifact)
    }

    func testActiveLoadCannotOverwriteConcurrentCompletedSaveUsingSharedGate() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let mutationAttempt = DispatchSemaphore(value: 0)
        let gate = RecordingSessionMutationGate(
            mutationAttemptObserver: { mutationAttempt.signal() }
        )
        try fixture.generatingStateData().write(to: fixture.stateURL)
        let barrier = SnapshotBarrierFileAccess(blocking: MeetingIntelligenceStateStore.fileName)
        let store = MeetingIntelligenceStateStore(mutationGate: gate, fileAccess: barrier)
        let loadDone = DispatchSemaphore(value: 0)
        let saveDone = DispatchSemaphore(value: 0)
        var loadError: Error?
        var saveError: Error?

        DispatchQueue.global().async {
            defer { loadDone.signal() }
            do { _ = try store.load(in: fixture.folder) } catch { loadError = error }
        }
        XCTAssertEqual(mutationAttempt.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(barrier.snapshotTaken.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            defer { saveDone.signal() }
            do { try store.save(fixture.state(), in: fixture.folder) } catch { saveError = error }
        }
        XCTAssertEqual(mutationAttempt.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(barrier.snapshotCount, 1)
        barrier.releaseSnapshot.signal()
        XCTAssertEqual(barrier.secondSnapshotTaken.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(loadDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(saveDone.wait(timeout: .now() + 1), .success)
        XCTAssertNil(loadError)
        XCTAssertNil(saveError)
        XCTAssertEqual(try store.load(in: fixture.folder)?.phase, .completed)
    }

    func testStateLoadUsesInjectedFileAccess() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let gate = RecordingSessionMutationGate()
        let access = StaticSnapshotFileAccess(data: fixture.stateData())
        let store = MeetingIntelligenceStateStore(mutationGate: gate, fileAccess: access)

        XCTAssertEqual(try store.load(in: fixture.folder), fixture.state())
        XCTAssertEqual(access.snapshotCalls, 1)
    }
}

private final class MeetingIntelligenceStoreFixture {
    let root: URL
    let folder: URL
    let artifactURL: URL
    let stateURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-intelligence-store-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("meeting", isDirectory: true)
        artifactURL = folder.appendingPathComponent(MeetingIntelligenceArtifactStore.fileName)
        stateURL = folder.appendingPathComponent(MeetingIntelligenceStateStore.fileName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func artifact(
        summary: String = "Summary",
        title: String = "Title",
        hash: String = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        byteCount: Int = 3,
        model: String = "model",
        generatedAt: Date = Date(timeIntervalSince1970: 1_785_427_200)
    ) -> MeetingIntelligenceArtifact {
        .init(
            schemaVersion: 1,
            summary: summary,
            suggestedTitle: title,
            sourceTranscriptSHA256: hash,
            sourceTranscriptByteCount: byteCount,
            model: model,
            generatedAt: generatedAt,
            intent: .generate
        )
    }

    func writeExistingArtifact() throws -> Data {
        let data = try JSONEncoder.meetingIntelligence.encode(artifact())
        try data.write(to: artifactURL)
        return data
    }

    func state() -> MeetingIntelligenceState {
        .init(schemaVersion: 1, phase: .completed, message: "Completed", sourceTranscriptSHA256: nil, startedAt: Date(timeIntervalSince1970: 1), finishedAt: nil)
    }

    func stateData() -> Data {
        try! JSONEncoder.meetingIntelligence.encode(state())
    }

    func generatingStateData() -> Data {
        try! JSONEncoder.meetingIntelligence.encode(
            MeetingIntelligenceState(
                schemaVersion: 1,
                phase: .generating,
                message: "Generating",
                sourceTranscriptSHA256: nil,
                startedAt: Date(timeIntervalSince1970: 1),
                finishedAt: nil
            )
        )
    }

    func writePadded(_ prefix: Data, to url: URL, count: Int) throws {
        XCTAssertLessThanOrEqual(prefix.count, count)
        try (prefix + Data(repeating: 0x20, count: count - prefix.count)).write(to: url)
    }
}

private final class ScriptedFileAccess: MeetingIntelligenceStoreFileAccess, @unchecked Sendable {
    private let base = DarwinMeetingIntelligenceStoreFileAccess()
    private let renameHook: ((URL, String, String) throws -> Void)?
    private let removeHook: ((URL, String) throws -> Void)?
    private let renameError: MeetingIntelligenceStoreError?
    private(set) var renameCalls = 0
    private(set) var removeCalls = 0

    init(
        renameError: MeetingIntelligenceStoreError? = nil,
        renameHook: ((URL, String, String) throws -> Void)? = nil,
        removeHook: ((URL, String) throws -> Void)? = nil
    ) {
        self.renameError = renameError
        self.renameHook = renameHook
        self.removeHook = removeHook
    }

    func snapshot(named name: String, in folder: URL, maximumBytes: Int) throws -> MeetingIntelligenceStoreFileSnapshot? {
        try base.snapshot(named: name, in: folder, maximumBytes: maximumBytes)
    }

    func create(named name: String, data: Data, in folder: URL) throws -> MeetingIntelligenceStoreFileSnapshot {
        try base.create(named: name, data: data, in: folder)
    }

    func promote(_ staged: MeetingIntelligenceStoreFileSnapshot, to destinationName: String, over destination: MeetingIntelligenceStoreFileSnapshot?, in folder: URL) throws {
        try renameHook?(folder, staged.name, destinationName)
        if let renameError { throw renameError }
        try base.promote(staged, to: destinationName, over: destination, in: folder)
        renameCalls += 1
    }

    func remove(_ destination: MeetingIntelligenceStoreFileSnapshot, in folder: URL) throws {
        try removeHook?(folder, destination.name)
        try base.remove(destination, in: folder)
        removeCalls += 1
    }
}

private final class SnapshotBarrierFileAccess: MeetingIntelligenceStoreFileAccess, @unchecked Sendable {
    private let base = DarwinMeetingIntelligenceStoreFileAccess()
    private let blockingName: String
    private let lock = NSLock()
    private var shouldBlock = true
    let snapshotTaken = DispatchSemaphore(value: 0)
    let releaseSnapshot = DispatchSemaphore(value: 0)
    let secondSnapshotTaken = DispatchSemaphore(value: 0)
    private var snapshots = 0

    var snapshotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }

    init(blocking name: String) {
        blockingName = name
    }

    func snapshot(named name: String, in folder: URL, maximumBytes: Int) throws -> MeetingIntelligenceStoreFileSnapshot? {
        let snapshot = try base.snapshot(named: name, in: folder, maximumBytes: maximumBytes)
        lock.lock()
        snapshots += 1
        if snapshots == 2 { secondSnapshotTaken.signal() }
        let block = name == blockingName && shouldBlock
        if block { shouldBlock = false }
        lock.unlock()
        if block {
            snapshotTaken.signal()
            _ = releaseSnapshot.wait(timeout: .distantFuture)
        }
        return snapshot
    }

    func create(named name: String, data: Data, in folder: URL) throws -> MeetingIntelligenceStoreFileSnapshot {
        return try base.create(named: name, data: data, in: folder)
    }

    func promote(_ staged: MeetingIntelligenceStoreFileSnapshot, to destinationName: String, over destination: MeetingIntelligenceStoreFileSnapshot?, in folder: URL) throws {
        try base.promote(staged, to: destinationName, over: destination, in: folder)
    }

    func remove(_ destination: MeetingIntelligenceStoreFileSnapshot, in folder: URL) throws {
        try base.remove(destination, in: folder)
    }
}

private final class StaticSnapshotFileAccess: MeetingIntelligenceStoreFileAccess, @unchecked Sendable {
    private let base = DarwinMeetingIntelligenceStoreFileAccess()
    private let data: Data
    private(set) var snapshotCalls = 0

    init(data: Data) {
        self.data = data
    }

    func snapshot(named name: String, in folder: URL, maximumBytes: Int) throws -> MeetingIntelligenceStoreFileSnapshot? {
        snapshotCalls += 1
        let staged = try base.create(named: ".static-snapshot-\(UUID().uuidString)", data: data, in: folder)
        return .init(name: name, data: data, identity: staged.identity)
    }

    func create(named name: String, data: Data, in folder: URL) throws -> MeetingIntelligenceStoreFileSnapshot {
        try base.create(named: name, data: data, in: folder)
    }

    func promote(_ staged: MeetingIntelligenceStoreFileSnapshot, to destinationName: String, over destination: MeetingIntelligenceStoreFileSnapshot?, in folder: URL) throws {
        try base.promote(staged, to: destinationName, over: destination, in: folder)
    }

    func remove(_ destination: MeetingIntelligenceStoreFileSnapshot, in folder: URL) throws {
        try base.remove(destination, in: folder)
    }
}

private extension Data {
    func writeAndReturn(to url: URL) throws -> Data {
        try write(to: url)
        return self
    }
}

private extension JSONEncoder {
    static var meetingIntelligence: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
