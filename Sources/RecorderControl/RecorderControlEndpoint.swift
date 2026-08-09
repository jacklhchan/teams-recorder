import Darwin
import Foundation

public struct RecorderControlEndpoint: Sendable {
    public let socketPath: String

    public init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        let userID = getuid()
        let directoryPath = "/tmp/lmr-\(userID)"
        try Self.validateDirectory(at: directoryPath, ownedBy: userID)
        socketPath = "\(directoryPath)/\(Self.socketName(bundleIdentifier: bundleIdentifier))"
    }

    public static func socketName(bundleIdentifier: String?) -> String {
        bundleIdentifier?.hasSuffix(".staging") == true ? "staging.sock" : "production.sock"
    }

    private static func validateDirectory(at path: String, ownedBy userID: uid_t) throws {
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard mkdir(path, S_IRWXU) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard lstat(path, &metadata) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        let permissions = metadata.st_mode & 0o777
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == userID,
              permissions == 0o700 else {
            throw EndpointDirectoryError.invalid
        }
    }
}

private enum EndpointDirectoryError: Error {
    case invalid
}
