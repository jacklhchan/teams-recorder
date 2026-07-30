import XCTest
@testable import RecorderApp

final class RecorderGlassTests: XCTestCase {
    func testVersionBoundary() {
        XCTAssertEqual(RecorderGlassStyle.resolve(majorVersion: 25), .material)
        XCTAssertEqual(RecorderGlassStyle.resolve(majorVersion: 26), .glass)
    }

    func testSourceKeepsCompileAndRuntimeAvailabilityBoundaries() throws {
        let source = try source(named: "RecorderGlass.swift")

        XCTAssertTrue(source.contains("#if compiler(>=6.2)"))
        XCTAssertTrue(source.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(source.contains("content.glassEffect()"))
        XCTAssertTrue(source.contains("fallback(content)"))
        XCTAssertFalse(source.contains("#if swift(>=6.2)"))
    }

    func testWorkspaceUsesGlassOnlyForSidebarNavigationChrome() throws {
        let workspace = try source(named: "ContentView.swift")
        let productionSources = try productionSourceFiles()
        let callers = productionSources.filter { $0.value.contains(".recorderGlass()") }

        XCTAssertEqual(callers.count, 1)
        XCTAssertEqual(callers.keys.map(\.lastPathComponent), ["ContentView.swift"])
        XCTAssertTrue(workspace.contains("RecorderSidebar(selection: selection)\n                .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)\n                .recorderGlass()"))
        let sidebar = try source(named: "RecorderSidebar.swift")
        XCTAssertTrue(sidebar.contains(".listStyle(.sidebar)\n        .scrollContentBackground(.hidden)"))
        for file in ["RecordDashboardView.swift", "RecordingsLibraryView.swift", "RecorderSettingsView.swift"] {
            XCTAssertFalse(try source(named: file).contains(".recorderGlass()"))
        }
    }

    private func source(named name: String) throws -> String {
        let sourceDirectory = name == "ContentView.swift"
            ? repositoryRoot.appendingPathComponent("Sources/RecorderApp")
            : repositoryRoot.appendingPathComponent("Sources/RecorderApp/UI")
        return try String(
            contentsOf: sourceDirectory.appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func productionSourceFiles() throws -> [URL: String] {
        let sources = repositoryRoot.appendingPathComponent("Sources/RecorderApp")
        let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
            .map { sources.appendingPathComponent($0) }
        return try Dictionary(uniqueKeysWithValues: files.map { file in
            (file, try String(contentsOf: file, encoding: .utf8))
        })
    }
}
