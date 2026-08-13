import Darwin
import Foundation

/// A deliberately small support artifact. It contains only typed operational
/// diagnostics, never recording/session content or local configuration.
struct SafeSupportBundle: Encodable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumDiagnostics = 100

    let schemaVersion: Int
    let generatedAt: Date
    let build: SafeSupportBundleBuild
    let diagnostics: [SafeRecordingDiagnostic]

    private init(
        schemaVersion: Int,
        generatedAt: Date,
        build: SafeSupportBundleBuild,
        diagnostics: [SafeRecordingDiagnostic]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.build = build
        self.diagnostics = diagnostics
    }

    static func make(
        build: SafeSupportBundleBuild,
        generatedAt: Date = Date(),
        diagnostics: [SafeRecordingDiagnostic] = []
    ) -> SafeSupportBundle {
        .init(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            build: build,
            diagnostics: Array(diagnostics.prefix(maximumDiagnostics))
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, build, diagnostics
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(
            ISO8601DateFormatter().string(from: generatedAt),
            forKey: .generatedAt
        )
        try container.encode(build, forKey: .build)
        try container.encode(diagnostics, forKey: .diagnostics)
    }
}

enum SafeSupportBundleChannel: String, Encodable, Equatable, Sendable {
    case development
    case staging
    case production
}

struct SafeSupportBundleBuild: Encodable, Equatable, Sendable {
    static let maximumBuildNumber = 9_999_999

    let channel: SafeSupportBundleChannel
    let versionMajor: Int
    let versionMinor: Int
    let versionPatch: Int
    let buildNumber: Int

    private init(
        channel: SafeSupportBundleChannel,
        versionMajor: Int,
        versionMinor: Int,
        versionPatch: Int,
        buildNumber: Int
    ) {
        self.channel = channel
        self.versionMajor = Self.bounded(versionMajor)
        self.versionMinor = Self.bounded(versionMinor)
        self.versionPatch = Self.bounded(versionPatch)
        self.buildNumber = Self.bounded(buildNumber)
    }

    static func make(
        channel: SafeSupportBundleChannel,
        versionMajor: Int,
        versionMinor: Int,
        versionPatch: Int,
        buildNumber: Int
    ) -> SafeSupportBundleBuild {
        .init(
            channel: channel,
            versionMajor: versionMajor,
            versionMinor: versionMinor,
            versionPatch: versionPatch,
            buildNumber: buildNumber
        )
    }

    private static func bounded(_ value: Int) -> Int {
        min(max(0, value), maximumBuildNumber)
    }
}

enum SafeSupportBundleStoreError: Error, Equatable {
    case unsafeRootDirectory
    case artifactWriteFailed
    case artifactTooLarge
}

/// Internal export API. Callers provide an app-owned directory; the exporter
/// creates it at 0700 and refuses an existing directory that is not owner-only.
struct SafeSupportBundleStore: Sendable {
    static let maximumArtifactBytes = 64 * 1_024

    let rootDirectory: URL

    func export(_ bundle: SafeSupportBundle) throws -> URL {
        let data = try JSONEncoder().encode(bundle)
        guard data.count <= Self.maximumArtifactBytes else {
            throw SafeSupportBundleStoreError.artifactTooLarge
        }
        try ensureOwnerOnlyRoot()

        let rootDescriptor = open(
            rootDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw SafeSupportBundleStoreError.unsafeRootDirectory
        }
        defer { Darwin.close(rootDescriptor) }

        let name = "support-bundle-\(UUID().uuidString).json"
        let temporaryName = ".\(name).tmp"
        let descriptor = openat(
            rootDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw SafeSupportBundleStoreError.artifactWriteFailed
        }
        defer {
            Darwin.close(descriptor)
            _ = unlinkat(rootDescriptor, temporaryName, 0)
        }

        guard fchmod(descriptor, 0o600) == 0 else {
            throw SafeSupportBundleStoreError.artifactWriteFailed
        }
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0,
              renameat(rootDescriptor, temporaryName, rootDescriptor, name) == 0 else {
            throw SafeSupportBundleStoreError.artifactWriteFailed
        }
        _ = fsync(rootDescriptor)
        return rootDirectory.appendingPathComponent(name)
    }

    private func ensureOwnerOnlyRoot() throws {
        if mkdir(rootDirectory.path, 0o700) == 0 {
            guard chmod(rootDirectory.path, 0o700) == 0 else {
                throw SafeSupportBundleStoreError.unsafeRootDirectory
            }
        } else if errno != EEXIST {
            throw SafeSupportBundleStoreError.unsafeRootDirectory
        }

        var attributes = stat()
        guard rootDirectory.path.withCString({ lstat($0, &attributes) }) == 0,
              (attributes.st_mode & S_IFMT) == S_IFDIR,
              attributes.st_uid == getuid(),
              (attributes.st_mode & 0o077) == 0 else {
            throw SafeSupportBundleStoreError.unsafeRootDirectory
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else { return }
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw SafeSupportBundleStoreError.artifactWriteFailed
                }
                offset += Int(count)
            }
        }
    }
}
