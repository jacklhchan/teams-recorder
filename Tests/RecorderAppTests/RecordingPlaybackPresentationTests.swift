import CoreGraphics
import Foundation
import XCTest
@testable import RecorderApp

final class RecordingPlaybackPresentationTests: XCTestCase {
    func testVideoPresentationFormatsTimesTargetsBadgesAndSizing() {
        let session = makeSession(
            fileExtension: "mp4",
            title: "Weekly sync",
            mediaKind: .video,
            source: .teamsAutomatic
        )

        let presentation = RecordingPlaybackPresentation.make(
            session: session,
            progress: 61,
            duration: 125
        )

        XCTAssertEqual(presentation.title, "Weekly sync")
        XCTAssertTrue(presentation.detailText.contains("recording.mp4"))
        XCTAssertTrue(presentation.detailText.contains("02:05"))
        XCTAssertEqual(presentation.elapsedText, "01:01")
        XCTAssertEqual(presentation.remainingText, "-01:04")
        XCTAssertEqual(presentation.totalText, "02:05")
        XCTAssertEqual(presentation.skipBackwardTarget, 46)
        XCTAssertEqual(presentation.skipForwardTarget, 76)
        XCTAssertEqual(presentation.mediaLabel, "Video")
        XCTAssertEqual(presentation.sourceLabel, "Teams automatic")
        XCTAssertNil(presentation.recoveryLabel)
        XCTAssertEqual(presentation.defaultContentSize, CGSize(width: 980, height: 720))
        XCTAssertEqual(presentation.minimumContentSize, CGSize(width: 680, height: 520))
    }

    func testAudioOnlyPresentationClampsSkipTargetsAndUsesCompactSizing() {
        let session = makeSession(
            fileExtension: "m4a",
            title: nil,
            mediaKind: .audio,
            source: .manual
        )

        let presentation = RecordingPlaybackPresentation.make(
            session: session,
            progress: 5,
            duration: 10
        )

        XCTAssertEqual(presentation.title, session.folderURL.lastPathComponent)
        XCTAssertEqual(presentation.skipBackwardTarget, 0)
        XCTAssertEqual(presentation.skipForwardTarget, 10)
        XCTAssertEqual(presentation.mediaLabel, "Audio only")
        XCTAssertEqual(presentation.sourceLabel, "Manual")
        XCTAssertNil(presentation.recoveryLabel)
        XCTAssertEqual(presentation.defaultContentSize, CGSize(width: 720, height: 360))
        XCTAssertEqual(presentation.minimumContentSize, CGSize(width: 600, height: 300))
    }

    func testHourLongPresentationUsesHoursForEveryTimelineValue() {
        let presentation = RecordingPlaybackPresentation.make(
            session: makeSession(
                fileExtension: "m4a",
                title: "Long recording",
                mediaKind: .audio,
                source: .imported
            ),
            progress: 61,
            duration: 3_600
        )

        XCTAssertEqual(presentation.elapsedText, "00:01:01")
        XCTAssertEqual(presentation.remainingText, "-00:58:59")
        XCTAssertEqual(presentation.totalText, "01:00:00")
        XCTAssertEqual(presentation.sourceLabel, "Imported")
    }

    func testRecoveryLabelsAreFactualAndDoNotClaimCaptureHealth() {
        let videoLost = RecordingPlaybackPresentation.make(
            session: makeSession(
                fileExtension: "m4a",
                title: "Recovered audio",
                mediaKind: .audio,
                source: .teamsAutomatic,
                recoveryState: .videoLostAudioPreserved
            ),
            progress: 0,
            duration: 12
        )
        let interrupted = RecordingPlaybackPresentation.make(
            session: makeSession(
                fileExtension: "m4a",
                title: "Interrupted recording",
                mediaKind: .audio,
                source: .manual,
                recoveryState: .recoveredAfterInterruption
            ),
            progress: 0,
            duration: 12
        )

        XCTAssertEqual(videoLost.recoveryLabel, "Video lost; audio preserved")
        XCTAssertEqual(interrupted.recoveryLabel, "Recovered after interruption")
        let factualLabels = [
            videoLost.mediaLabel,
            videoLost.sourceLabel,
            videoLost.recoveryLabel,
            interrupted.mediaLabel,
            interrupted.sourceLabel,
            interrupted.recoveryLabel
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        XCTAssertFalse(factualLabels.contains("system audio"))
        XCTAssertFalse(factualLabels.contains("microphone"))
    }

    private func makeSession(
        fileExtension: String,
        title: String?,
        mediaKind: RecordingMediaKind,
        source: RecordingSource,
        recoveryState: RecordingRecoveryState = .none
    ) -> RecordingSession {
        let folder = URL(
            fileURLWithPath: "/tmp/meeting-presentation-fixture",
            isDirectory: true
        )
        return RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.\(fileExtension)"),
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 12,
            fileSize: 1_024,
            metadata: .init(
                title: title,
                mediaKind: mediaKind,
                recoveryState: recoveryState,
                source: source
            )
        )
    }
}
