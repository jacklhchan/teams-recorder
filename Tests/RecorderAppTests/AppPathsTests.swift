import Foundation
import XCTest
@testable import RecorderApp

final class AppPathsTests: XCTestCase {
    func testAppPathsOwnPendingRecordingsAndManifestUnderAppSupport() {
        let root = URL(fileURLWithPath: "/Users/test/Library/Application Support", isDirectory: true)
        let paths = AppPaths(
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            applicationSupportRoot: root
        )

        XCTAssertEqual(
            paths.pendingRecordingsDirectory.path,
            "/Users/test/Library/Application Support/Local Meeting Recorder/Pending Recordings"
        )
        XCTAssertEqual(
            paths.recordingPublicationManifestURL.path,
            "/Users/test/Library/Application Support/Local Meeting Recorder/Pending Recordings/publication-queue-v1.json"
        )
    }

    func testPathsAreDerivedFromCurrentUserInsteadOfDeveloperHome() {
        let home = URL(fileURLWithPath: "/Users/colleague", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let paths = AppPaths(homeDirectory: home, applicationSupportRoot: support)

        XCTAssertEqual(paths.recordingsDirectory.path, "/Users/colleague/Downloads")
        XCTAssertEqual(paths.appSupportDirectory.path, "/Users/colleague/Library/Application Support/Local Meeting Recorder")
        XCTAssertEqual(paths.setupLogURL.lastPathComponent, "setup.log")
        XCTAssertEqual(paths.omlxSettingsURL.path, "/Users/colleague/.omlx/settings.json")
        XCTAssertFalse(paths.omlxSettingsURL.path.contains("/Users/apple"))
        XCTAssertFalse(paths.appSupportDirectory.path.contains("/Users/apple"))
    }
}
