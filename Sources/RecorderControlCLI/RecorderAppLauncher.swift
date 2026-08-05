import Foundation

struct RecorderAppLauncher: RecorderAppLaunching {
    let applicationURL: URL
    let bundleIdentifier: String

    init(executablePath: String) throws {
        let executableURL = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let helpersURL = executableURL.deletingLastPathComponent()
        let contentsURL = helpersURL.deletingLastPathComponent()
        let applicationURL = contentsURL.deletingLastPathComponent()

        guard executableURL.lastPathComponent == "recorderctl",
              helpersURL.lastPathComponent == "Helpers",
              contentsURL.lastPathComponent == "Contents",
              applicationURL.pathExtension == "app" else {
            throw RecorderAppLauncherError.invalidBundleLayout
        }

        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        let infoPlistData = try Data(contentsOf: infoPlistURL)
        guard let info = try PropertyListSerialization.propertyList(
            from: infoPlistData,
            options: [],
            format: nil
        ) as? [String: Any],
        let bundleIdentifier = info["CFBundleIdentifier"] as? String,
        !bundleIdentifier.isEmpty else {
            throw RecorderAppLauncherError.missingBundleIdentifier
        }

        self.applicationURL = applicationURL
        self.bundleIdentifier = bundleIdentifier
    }

    func launchInBackground() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-gj",
            applicationURL.path,
            "--args",
            "--background-control"
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RecorderAppLauncherError.openFailed(process.terminationStatus)
        }
    }
}

private enum RecorderAppLauncherError: LocalizedError {
    case invalidBundleLayout
    case missingBundleIdentifier
    case openFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidBundleLayout:
            return "recorderctl must be located at <app>/Contents/Helpers/recorderctl."
        case .missingBundleIdentifier:
            return "The containing app Info.plist has no CFBundleIdentifier."
        case let .openFailed(status):
            return "/usr/bin/open exited with status \(status)."
        }
    }
}
