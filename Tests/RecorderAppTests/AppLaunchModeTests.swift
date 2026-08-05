@testable import RecorderApp
import XCTest

final class AppLaunchModeTests: XCTestCase {
    func testNormalArgumentsSelectInteractiveLaunch() {
        XCTAssertEqual(AppLaunchMode(arguments: ["LocalMeetingRecorder"]), .interactive)
    }

    func testBackgroundControlFlagSelectsBackgroundLaunch() {
        XCTAssertEqual(
            AppLaunchMode(arguments: ["LocalMeetingRecorder", "--background-control"]),
            .backgroundControl
        )
    }
}
