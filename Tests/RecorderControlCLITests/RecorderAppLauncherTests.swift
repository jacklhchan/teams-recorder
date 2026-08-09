import Foundation
@testable import RecorderControlCLI
import XCTest

final class RecorderAppLauncherTests: XCTestCase {
    func testCurrentExecutablePathResolvesInstalledSymlinkToContainingApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let applicationURL = root.appendingPathComponent("Recorder.app", isDirectory: true)
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(
            at: helpersURL,
            withIntermediateDirectories: true
        )
        let executableURL = helpersURL.appendingPathComponent("recorderctl")
        try Data().write(to: executableURL)
        let info = ["CFBundleIdentifier": "com.example.recorder"]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: contentsURL.appendingPathComponent("Info.plist"))

        let pathDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: pathDirectory, withIntermediateDirectories: true)
        let symlinkURL = pathDirectory.appendingPathComponent("recorderctl")
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: executableURL.path
        )

        let resolvedPath = try RecorderCLIExecutablePath.current { symlinkURL.path }
        let launcher = try RecorderAppLauncher(executablePath: resolvedPath)

        XCTAssertEqual(resolvedPath, executableURL.path)
        XCTAssertEqual(launcher.applicationURL, applicationURL)
        XCTAssertEqual(launcher.bundleIdentifier, "com.example.recorder")
    }
}
