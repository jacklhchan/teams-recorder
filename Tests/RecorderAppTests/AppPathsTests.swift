import Foundation
import XCTest
@testable import RecorderApp

final class AppPathsTests: XCTestCase {
    func testPathsAreDerivedFromCurrentUserInsteadOfDeveloperHome() {
        let home = URL(fileURLWithPath: "/Users/colleague", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let paths = AppPaths(homeDirectory: home, applicationSupportRoot: support)

        XCTAssertEqual(paths.recordingsDirectory.path, "/Users/colleague/Downloads")
        XCTAssertEqual(paths.appSupportDirectory.path, "/Users/colleague/Library/Application Support/Local Meeting Recorder")
        XCTAssertEqual(paths.setupLogURL.lastPathComponent, "setup.log")
        XCTAssertFalse(paths.appSupportDirectory.path.contains("/Users/apple"))
    }
}
