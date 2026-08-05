import Darwin
import Foundation

public enum RecorderControlSocketError: Error, Equatable {
    case invalidSocketPath
    case invalidExistingSocket
    case oversizedFrame
    case timedOut
    case connectionClosed
    case malformedFrame
    case peerUIDMismatch
}

public struct RecorderControlSocketClient: Sendable {
    public init() {}

    public func send(
        _ request: RecorderControlRequest,
        to endpoint: RecorderControlEndpoint,
        timeout: TimeInterval
    ) async throws -> RecorderControlResponse {
        try await send(request, to: endpoint.socketPath, timeout: timeout)
    }

    public func send(
        _ request: RecorderControlRequest,
        to socketPath: String,
        timeout: TimeInterval
    ) async throws -> RecorderControlResponse {
        try await Task.detached {
            let frame = try SocketFrame.encode(request)
            let descriptor = try SocketDescriptor.make()
            defer { Darwin.close(descriptor) }
            try SocketDescriptor.setNonBlocking(descriptor)
            let deadline = SocketDeadline(timeout: timeout)

            try SocketAddress.withValue(path: socketPath) { address, length in
                if Darwin.connect(descriptor, address, length) != 0 {
                    guard errno == EINPROGRESS else { throw SocketDescriptor.posixError() }
                    try SocketDescriptor.wait(
                        descriptor,
                        events: Int16(POLLOUT),
                        deadline: deadline
                    )
                    var connectionError: Int32 = 0
                    var connectionErrorLength = socklen_t(MemoryLayout.size(ofValue: connectionError))
                    guard getsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_ERROR,
                        &connectionError,
                        &connectionErrorLength
                    ) == 0 else {
                        throw SocketDescriptor.posixError()
                    }
                    guard connectionError == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: connectionError) ?? .EIO)
                    }
                }
            }

            try SocketDescriptor.write(frame, to: descriptor, deadline: deadline)
            let responseFrame = try SocketDescriptor.readFrame(
                from: descriptor,
                deadline: deadline
            )
            do {
                return try JSONDecoder().decode(RecorderControlResponse.self, from: responseFrame)
            } catch {
                throw RecorderControlSocketError.malformedFrame
            }
        }.value
    }
}

public final class RecorderControlSocketServer: @unchecked Sendable {
    public static let maximumFrameSize = 65_536

    public typealias Handler = @Sendable (RecorderControlRequest) async -> RecorderControlResponse
    typealias CurrentUID = @Sendable () -> uid_t
    typealias PeerUID = @Sendable (Int32) throws -> uid_t

    private let socketPathProvider: @Sendable () throws -> String
    private let currentUID: CurrentUID
    private let peerUID: PeerUID
    private let handler: Handler
    private let stateLock = NSLock()
    private let acceptGroup = DispatchGroup()
    private var listener: Int32 = -1
    private var resolvedSocketPath: String?
    private var resolvedSocketIdentity: SocketIdentity?
    private var clients: Set<Int32> = []

    public init(
        bundleIdentifier: String?,
        handler: @escaping Handler
    ) {
        socketPathProvider = {
            try RecorderControlEndpoint(bundleIdentifier: bundleIdentifier).socketPath
        }
        currentUID = { getuid() }
        peerUID = { descriptor in
            try Self.actualPeerUID(descriptor)
        }
        self.handler = handler
    }

    init(
        socketPath: String,
        currentUID: @escaping CurrentUID = { getuid() },
        peerUID: @escaping PeerUID = { descriptor in
            try RecorderControlSocketServer.actualPeerUID(descriptor)
        },
        handler: @escaping Handler
    ) {
        socketPathProvider = { socketPath }
        self.currentUID = currentUID
        self.peerUID = peerUID
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        stateLock.lock()
        let alreadyStarted = listener >= 0
        stateLock.unlock()
        guard !alreadyStarted else { return }

        let socketPath = try socketPathProvider()
        try removeExistingSocket(at: socketPath)
        let descriptor = try SocketDescriptor.make()
        var bound = false
        var boundIdentity: SocketIdentity?
        do {
            try SocketAddress.withValue(path: socketPath) { address, length in
                guard Darwin.bind(descriptor, address, length) == 0 else {
                    throw SocketDescriptor.posixError()
                }
            }
            bound = true
            boundIdentity = try SocketIdentity.read(at: socketPath)
            guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
                throw SocketDescriptor.posixError()
            }
            guard Darwin.listen(descriptor, 8) == 0 else {
                throw SocketDescriptor.posixError()
            }

            stateLock.lock()
            guard listener < 0 else {
                stateLock.unlock()
                Darwin.close(descriptor)
                return
            }
            listener = descriptor
            resolvedSocketPath = socketPath
            resolvedSocketIdentity = boundIdentity
            stateLock.unlock()
        } catch {
            Darwin.close(descriptor)
            if bound {
                try? removeOwnedSocket(at: socketPath, matching: boundIdentity)
            }
            throw error
        }

        acceptGroup.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            acceptConnections(on: descriptor)
            acceptGroup.leave()
        }
    }

    public func stop() {
        stateLock.lock()
        let descriptor = listener
        listener = -1
        let socketPath = resolvedSocketPath
        resolvedSocketPath = nil
        let socketIdentity = resolvedSocketIdentity
        resolvedSocketIdentity = nil
        for client in clients {
            Darwin.shutdown(client, SHUT_RDWR)
        }
        stateLock.unlock()

        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            acceptGroup.wait()
        }
        if let socketPath {
            try? removeOwnedSocket(at: socketPath, matching: socketIdentity)
        }
    }

    private func acceptConnections(on descriptor: Int32) {
        while isCurrentListener(descriptor) {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            do {
                try SocketDescriptor.preventSIGPIPE(client)
            } catch {
                Darwin.close(client)
                continue
            }
            guard register(client, for: descriptor) else {
                Darwin.close(client)
                return
            }
            Task.detached { [self] in
                await process(client)
            }
        }
    }

    private func process(_ descriptor: Int32) async {
        defer { finishClient(descriptor) }
        do {
            guard try peerUID(descriptor) == currentUID() else {
                throw RecorderControlSocketError.peerUIDMismatch
            }
            let requestFrame = try SocketDescriptor.readFrame(from: descriptor)
            let request: RecorderControlRequest
            do {
                request = try JSONDecoder().decode(RecorderControlRequest.self, from: requestFrame)
            } catch {
                throw RecorderControlSocketError.malformedFrame
            }
            let response = await handler(request)
            let responseFrame = try SocketFrame.encode(response)
            try SocketDescriptor.write(responseFrame, to: descriptor)
        } catch {
            return
        }
    }

    private func finishClient(_ descriptor: Int32) {
        stateLock.lock()
        clients.remove(descriptor)
        stateLock.unlock()
        Darwin.close(descriptor)
    }

    private func isCurrentListener(_ descriptor: Int32) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listener == descriptor
    }

    private func register(_ client: Int32, for descriptor: Int32) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard listener == descriptor else { return false }
        clients.insert(client)
        return true
    }

    private func removeExistingSocket(at socketPath: String) throws {
        var metadata = stat()
        guard lstat(socketPath, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw SocketDescriptor.posixError()
        }
        guard metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_uid == currentUID() else {
            throw RecorderControlSocketError.invalidExistingSocket
        }
        guard unlink(socketPath) == 0 else { throw SocketDescriptor.posixError() }
    }

    private func removeOwnedSocket(
        at socketPath: String,
        matching identity: SocketIdentity?
    ) throws {
        var metadata = stat()
        guard lstat(socketPath, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw SocketDescriptor.posixError()
        }
        guard metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_uid == currentUID(),
              identity == nil || identity == SocketIdentity(metadata: metadata) else {
            return
        }
        guard unlink(socketPath) == 0 else { throw SocketDescriptor.posixError() }
    }

    private static func actualPeerUID(_ descriptor: Int32) throws -> uid_t {
        var userID: uid_t = 0
        var groupID: gid_t = 0
        guard getpeereid(descriptor, &userID, &groupID) == 0 else {
            throw SocketDescriptor.posixError()
        }
        return userID
    }
}

private struct SocketIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
    }

    static func read(at path: String) throws -> SocketIdentity {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw SocketDescriptor.posixError()
        }
        return SocketIdentity(metadata: metadata)
    }
}

private enum SocketFrame {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        guard data.count <= RecorderControlSocketServer.maximumFrameSize else {
            throw RecorderControlSocketError.oversizedFrame
        }
        return data
    }
}

private enum SocketAddress {
    static func withValue<Result>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < pathCapacity else {
            throw RecorderControlSocketError.invalidSocketPath
        }
        let length = MemoryLayout.offset(of: \sockaddr_un.sun_path)! + bytes.count + 1
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: pathCapacity) { pathPointer in
                for (index, byte) in bytes.enumerated() {
                    pathPointer[index] = byte
                }
                pathPointer[bytes.count] = 0
            }
        }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(length))
            }
        }
    }
}

private struct SocketDeadline: Sendable {
    let uptimeNanoseconds: UInt64

    init(timeout: TimeInterval) {
        let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        uptimeNanoseconds = DispatchTime.now().uptimeNanoseconds &+ nanoseconds
    }

    var remainingMilliseconds: Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < uptimeNanoseconds else { return 0 }
        let remaining = (uptimeNanoseconds - now) / 1_000_000
        return Int32(min(UInt64(Int32.max), max(1, remaining)))
    }
}

private enum SocketDescriptor {
    static func make() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError() }
        do {
            try preventSIGPIPE(descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    static func preventSIGPIPE(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout.size(ofValue: enabled))
        ) == 0 else {
            throw posixError()
        }
    }

    static func setNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw posixError()
        }
    }

    static func wait(
        _ descriptor: Int32,
        events: Int16,
        deadline: SocketDeadline
    ) throws {
        while true {
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, deadline.remainingMilliseconds)
            if result > 0 {
                if item.revents & events != 0 { return }
                guard item.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)) == 0 else {
                    throw RecorderControlSocketError.connectionClosed
                }
                return
            }
            if result == 0 { throw RecorderControlSocketError.timedOut }
            if errno != EINTR { throw posixError() }
        }
    }

    static func readFrame(
        from descriptor: Int32,
        deadline: SocketDeadline? = nil
    ) throws -> Data {
        var frame = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while frame.count < RecorderControlSocketServer.maximumFrameSize {
            if let deadline {
                try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            }
            let capacity = min(
                buffer.count,
                RecorderControlSocketServer.maximumFrameSize - frame.count
            )
            let count = Darwin.read(descriptor, &buffer, capacity)
            if count > 0 {
                frame.append(buffer, count: count)
                if let newline = frame.firstIndex(of: 0x0A) {
                    return frame.prefix(upTo: newline)
                }
                continue
            }
            if count == 0 { throw RecorderControlSocketError.connectionClosed }
            if errno == EINTR { continue }
            if deadline != nil, errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw posixError()
        }
        throw RecorderControlSocketError.oversizedFrame
    }

    static func write(
        _ data: Data,
        to descriptor: Int32,
        deadline: SocketDeadline? = nil
    ) throws {
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while offset < data.count {
                if let deadline {
                    try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                }
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                if deadline != nil, count < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw posixError()
            }
        }
    }

    static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
