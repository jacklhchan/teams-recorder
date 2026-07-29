import Foundation

struct AppPaths: Sendable {
    let homeDirectory: URL
    let applicationSupportRoot: URL

    static let live = AppPaths(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportRoot: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    )

    var recordingsDirectory: URL {
        homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    var appSupportDirectory: URL {
        applicationSupportRoot.appendingPathComponent("Local Meeting Recorder", isDirectory: true)
    }

    var setupLogURL: URL {
        appSupportDirectory.appendingPathComponent("setup.log")
    }

    var diagnosticsDirectory: URL {
        appSupportDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    var omlxSettingsURL: URL {
        homeDirectory.appendingPathComponent(".omlx/settings.json")
    }
}
