import AppKit
import AVFoundation
import Darwin
import Foundation
import ScreenCaptureKit

enum ProbeError: Error, CustomStringConvertible {
    case usage
    case socket(String)
    case bookmarkMissing
    case bookmarkStale
    case process(Int32)

    var description: String {
        switch self {
        case .usage: return "usage"
        case .socket(let message): return message
        case .bookmarkMissing: return "bookmark-missing"
        case .bookmarkStale: return "bookmark-stale"
        case .process(let status): return "helper-exit-\(status)"
        }
    }
}

@main
struct AppSandboxSpike {
    static func main() async {
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "capture-status": try await captureStatus()
            case "bookmark-select": try selectBookmark()
            case "bookmark-verify": try verifyBookmark()
            case "bookmark-cleanup": try cleanupBookmark()
            case "pending-create": try pendingCreate()
            case "pending-recover": try pendingRecover()
            case "ipc-embedded": try embeddedIPC()
            case "serve-once":
                guard CommandLine.arguments.count == 3 else { throw ProbeError.usage }
                try serveOnce(at: CommandLine.arguments[2])
            default: throw ProbeError.usage
            }
        } catch {
            print("sandbox-spike-error=\(error)")
            exit(1)
        }
    }

    static func containerRoot() throws -> URL {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ProbeError.socket("application-support-unavailable")
        }
        return root.appendingPathComponent("SandboxSpike", isDirectory: true)
    }

    static func captureStatus() async throws {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let screenResult: String
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            screenResult = "available(displays=\(content.displays.count),windows=\(content.windows.count))"
        } catch {
            screenResult = "error(\(String(describing: error)))"
        }
        print("capture.microphone-status=\(microphone.rawValue)")
        print("capture.screen-content=\(screenResult)")
    }

    static func bookmarkURL() throws -> URL {
        try containerRoot().appendingPathComponent("selected-folder.bookmark", isDirectory: false)
    }

    static func selectBookmark() throws {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else {
            throw ProbeError.bookmarkMissing
        }
        let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let root = try containerRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bookmark.write(to: try bookmarkURL(), options: .atomic)
        print("bookmark.selected=true")
    }

    static func verifyBookmark() throws {
        let data = try Data(contentsOf: try bookmarkURL())
        var stale = false
        let folder = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw ProbeError.bookmarkStale }
        guard folder.startAccessingSecurityScopedResource() else { throw ProbeError.socket("bookmark-access-denied") }
        defer { folder.stopAccessingSecurityScopedResource() }
        let probe = folder.appendingPathComponent("sandbox-spike-bookmark-\(UUID().uuidString).txt")
        try Data("fixture".utf8).write(to: probe, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: probe)
        print("bookmark.relaunch-access=true")
    }

    static func cleanupBookmark() throws {
        let bookmark = try bookmarkURL()
        if FileManager.default.fileExists(atPath: bookmark.path) {
            try FileManager.default.removeItem(at: bookmark)
        }
        print("bookmark.cleaned=true")
    }

    static func pendingCreate() throws {
        let root = try containerRoot()
        let pending = root.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let session = pending.appendingPathComponent("session.txt")
        try? FileManager.default.removeItem(at: session)
        try Data("pending".utf8).write(to: session, options: .withoutOverwriting)
        print("pending.created=true")
    }

    static func pendingRecover() throws {
        let root = try containerRoot()
        let pending = root.appendingPathComponent("pending", isDirectory: true)
        let published = root.appendingPathComponent("published", isDirectory: true)
        let session = pending.appendingPathComponent("session.txt")
        let destination = published.appendingPathComponent("session.txt")
        guard FileManager.default.fileExists(atPath: session.path) else {
            throw ProbeError.socket("pending-item-missing")
        }
        try FileManager.default.createDirectory(at: published, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: session, to: destination)
        let recovered = try String(contentsOf: destination, encoding: .utf8)
        guard recovered == "pending" else { throw ProbeError.socket("recovery-read-mismatch") }
        try FileManager.default.removeItem(at: root)
        print("pending.publish-recovery=true")
    }

    static func embeddedIPC() throws {
        // Keep below sockaddr_un's path limit and deliberately outside the
        // container: this is the current public AF_UNIX question under test.
        let endpoint = "/private/tmp/lmr-sbx-\(getpid()).sock"
        let server = Process()
        server.executableURL = Bundle.main.executableURL
        server.arguments = ["serve-once", endpoint]
        let serverOutput = Pipe()
        server.standardOutput = serverOutput
        try server.run()
        try waitForReadyMarker(from: serverOutput, server: server)
        let helper = Process()
        helper.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SandboxSpikeHelper")
        helper.arguments = [endpoint]
        try helper.run()
        helper.waitUntilExit()
        guard helper.terminationStatus == 0 else {
            reapServer(server)
            print("ipc.helper-exit=\(helper.terminationStatus)")
            print("ipc.server-exit=\(server.terminationStatus)")
            throw ProbeError.process(helper.terminationStatus)
        }
        server.waitUntilExit()
        print("ipc.helper-exit=\(helper.terminationStatus)")
        print("ipc.server-exit=\(server.terminationStatus)")
        guard server.terminationStatus == 0 else {
            throw ProbeError.process(server.terminationStatus)
        }
        print("ipc.embedded-helper=true")
    }

    static func reapServer(_ server: Process) {
        if server.isRunning {
            server.terminate()
        }
        server.waitUntilExit()
    }

    static func waitForReadyMarker(from output: Pipe, server: Process) throws {
        let data = output.fileHandleForReading.availableData
        let status = String(decoding: data, as: UTF8.self)
        guard status.contains("ipc.server-ready") else {
            server.waitUntilExit()
            print("ipc.server-result=not-ready")
            print("ipc.helper-exit=not-launched")
            throw ProbeError.socket("ipc.server-not-ready(status=\(status.trimmingCharacters(in: .whitespacesAndNewlines)),exit=\(server.terminationStatus))")
        }
        print("ipc.server-result=ready")
    }

    static func serveOnce(at path: String) throws {
        unlink(path)
        defer { unlink(path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProbeError.socket("socket-create") }
        defer { close(fd) }
        try withUnixAddress(path) { address, length in
            guard bind(fd, address, length) == 0 else { throw ProbeError.socket("socket-bind(errno=\(errno))") }
        }
        guard listen(fd, 1) == 0 else { throw ProbeError.socket("socket-listen") }
        FileHandle.standardOutput.write(Data("ipc.server-ready\n".utf8))
        let client = accept(fd, nil, nil)
        guard client >= 0 else { throw ProbeError.socket("socket-accept") }
        defer { close(client) }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard read(client, &bytes, bytes.count) == 4, bytes == Array("ping".utf8) else { throw ProbeError.socket("socket-read") }
        guard write(client, Array("pong".utf8), 4) == 4 else { throw ProbeError.socket("socket-write") }
    }

    static func withUnixAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ProbeError.socket("socket-path-too-long") }
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size - MemoryLayout.size(ofValue: address.sun_path) + bytes.count)
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, length)
            }
        }
    }
}
