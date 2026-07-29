import Foundation
import XCTest
@testable import RecorderApp

final class LegacyOMLXSettingsReaderTests: XCTestCase {
    func testReadsHostPortAndAPIKeyWithoutProviderDefaults() throws {
        let file = try writeSettings(
            """
            {
              "server": {"host": "127.0.0.1", "port": 8765},
              "auth": {"api_key": "legacy-secret"}
            }
            """
        )

        let settings = try LegacyOMLXSettingsReader().read(from: file)

        XCTAssertEqual(settings.baseURL.absoluteString, "http://127.0.0.1:8765/v1")
        XCTAssertEqual(settings.apiKey, "legacy-secret")
    }

    func testMapsWildcardBindHostToLoopbackClientHost() throws {
        let file = try writeSettings(
            """
            {
              "server": {"host": "0.0.0.0", "port": 8000},
              "auth": {"api_key": ""}
            }
            """
        )

        XCTAssertEqual(
            try LegacyOMLXSettingsReader().read(from: file).baseURL.host,
            "127.0.0.1"
        )
    }

    private func writeSettings(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try Data(contents.utf8).write(to: file)
        return file
    }
}
