import XCTest
@testable import RecorderControl

final class RecorderControlEndpointTests: XCTestCase {
    func testStagingBundleIdentifierUsesStagingSocket() {
        XCTAssertEqual(
            RecorderControlEndpoint.socketName(
                bundleIdentifier: "local.meeting.recorder.staging"
            ),
            "staging.sock"
        )
    }

    func testProductionBundleIdentifierUsesProductionSocketAndShortPath() throws {
        XCTAssertEqual(
            RecorderControlEndpoint.socketName(
                bundleIdentifier: "local.meeting.recorder"
            ),
            "production.sock"
        )

        let endpoint = try RecorderControlEndpoint(
            bundleIdentifier: "local.meeting.recorder"
        )
        XCTAssertLessThan(endpoint.socketPath.utf8.count, 100)
    }
}
