import Darwin
import Foundation

enum RecorderCLIExecutablePath {
    static func current(
        _ readRawPath: () throws -> String = readSystemExecutablePath
    ) throws -> String {
        let rawPath = try readRawPath()
        return URL(fileURLWithPath: rawPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func readSystemExecutablePath() throws -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else {
            throw RecorderAppLauncherError.executablePathUnavailable
        }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            throw RecorderAppLauncherError.executablePathUnavailable
        }
        return String(cString: buffer)
    }
}

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

    func launchInBackground() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-gj",
            applicationURL.path,
            "--args",
            "--background-control"
        ]
        try process.run()
        let status = try await ProcessTerminationWaiter(process: process).wait(timeout: 5)
        guard status == 0 else {
            throw RecorderAppLauncherError.openFailed(status)
        }
    }
}

private final class ProcessTerminationWaiter: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Error>?
    private var completedResult: Result<Int32, Error>?

    init(process: Process) {
        self.process = process
    }

    func wait(timeout: TimeInterval) async throws -> Int32 {
        process.terminationHandler = { [weak self] process in
            self?.finish(with: .success(process.terminationStatus))
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
                if !process.isRunning {
                    finish(with: .success(process.terminationStatus))
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(
                        with: .failure(RecorderAppLauncherError.openTimedOut),
                        terminating: true
                    )
                }
            }
        } onCancel: {
            self.finish(with: .failure(CancellationError()), terminating: true)
        }
    }

    private func install(_ continuation: CheckedContinuation<Int32, Error>) {
        lock.lock()
        if let completedResult {
            lock.unlock()
            continuation.resume(with: completedResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func finish(
        with result: Result<Int32, Error>,
        terminating: Bool = false
    ) {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if terminating, process.isRunning {
            process.terminate()
        }
        continuation?.resume(with: result)
    }
}

private enum RecorderAppLauncherError: LocalizedError {
    case executablePathUnavailable
    case invalidBundleLayout
    case missingBundleIdentifier
    case openFailed(Int32)
    case openTimedOut

    var errorDescription: String? {
        switch self {
        case .executablePathUnavailable:
            return "Unable to resolve the recorderctl executable path."
        case .invalidBundleLayout:
            return "recorderctl must be located at <app>/Contents/Helpers/recorderctl."
        case .missingBundleIdentifier:
            return "The containing app Info.plist has no CFBundleIdentifier."
        case let .openFailed(status):
            return "/usr/bin/open exited with status \(status)."
        case .openTimedOut:
            return "/usr/bin/open did not exit within 5 seconds."
        }
    }
}
