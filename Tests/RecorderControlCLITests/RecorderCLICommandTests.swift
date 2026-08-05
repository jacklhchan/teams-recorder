import RecorderControl
@testable import RecorderControlCLI
import XCTest

final class RecorderCLICommandTests: XCTestCase {
    func testParsesApprovedCommands() throws {
        let cases: [([String], RecorderCLICommand)] = [
            (["status"], .status(json: false)),
            (["status", "--json"], .status(json: true)),
            (["watch", "--json"], .watch(json: true)),
            (["start"], .request(.start, nil)),
            (["stop"], .request(.stop, nil)),
            (["auto", "on"], .request(.setAuto, "on")),
            (["auto", "off"], .request(.setAuto, "off")),
            (["mic", "mute"], .request(.setMic, "mute")),
            (["mic", "unmute"], .request(.setMic, "unmute"))
        ]

        for (arguments, expected) in cases {
            XCTAssertEqual(try RecorderCLICommand(arguments: arguments), expected)
        }
    }

    func testRejectsMissingExtraAndUnknownArguments() {
        let rejected = [
            [],
            ["status", "--json", "extra"],
            ["watch", "--xml"],
            ["start", "extra"],
            ["auto"],
            ["auto", "maybe"],
            ["mic"],
            ["unknown"]
        ]

        for arguments in rejected {
            XCTAssertThrowsError(try RecorderCLICommand(arguments: arguments))
        }
    }
}
