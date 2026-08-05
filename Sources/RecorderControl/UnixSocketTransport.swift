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
    typealias SocketIdentityProvider = @Sendable (Int32, String, uid_t) throws -> SocketIdentity

    private let socketPathProvider: @Sendable () throws -> String
    private let currentUID: CurrentUID
    private let peerUID: PeerUID
    private let clientTimeout: TimeInterval
    private let socketIdentityProvider: SocketIdentityProvider
    private let beforeBind: @Sendable () -> Void
    private let beforeOwnedCleanup: @Sendable () -> Void
    private let beforeFinishedClientClose: @Sendable () -> Void
    private let handler: Handler
    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()
    private let acceptGroup = DispatchGroup()
    private var listener: Int32 = -1
    private var listenerGeneration: UInt64 = 0
    private var resolvedSocketPath: String?
    private var resolvedSocketIdentity: SocketIdentity?
    private var clients: [ObjectIdentifier: OwnedSocketDescriptor] = [:]

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
        clientTimeout = 5
        socketIdentityProvider = {
            try SocketIdentity.readBoundSocket(from: $0, at: $1, ownedBy: $2)
        }
        beforeBind = {}
        beforeOwnedCleanup = {}
        beforeFinishedClientClose = {}
        self.handler = handler
    }

    init(
        socketPath: String,
        currentUID: @escaping CurrentUID = { getuid() },
        peerUID: @escaping PeerUID = { descriptor in
            try RecorderControlSocketServer.actualPeerUID(descriptor)
        },
        requestTimeout: TimeInterval = 5,
        socketIdentityProvider: @escaping SocketIdentityProvider = {
            try SocketIdentity.readBoundSocket(from: $0, at: $1, ownedBy: $2)
        },
        beforeBind: @escaping @Sendable () -> Void = {},
        beforeOwnedCleanup: @escaping @Sendable () -> Void = {},
        beforeFinishedClientClose: @escaping @Sendable () -> Void = {},
        handler: @escaping Handler
    ) {
        socketPathProvider = { socketPath }
        self.currentUID = currentUID
        self.peerUID = peerUID
        clientTimeout = requestTimeout
        self.socketIdentityProvider = socketIdentityProvider
        self.beforeBind = beforeBind
        self.beforeOwnedCleanup = beforeOwnedCleanup
        self.beforeFinishedClientClose = beforeFinishedClientClose
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        stateLock.lock()
        let alreadyStarted = listener >= 0
        stateLock.unlock()
        guard !alreadyStarted else { return }

        let socketPath = try socketPathProvider()
        try removeExistingSocket(at: socketPath)
        let descriptor = try SocketDescriptor.make()
        var boundIdentity: SocketIdentity?
        do {
            beforeBind()
            try SocketAddress.withValue(path: socketPath) { address, length in
                guard Darwin.bind(descriptor, address, length) == 0 else {
                    throw SocketDescriptor.posixError()
                }
            }
            let identity = try socketIdentityProvider(descriptor, socketPath, currentUID())
            boundIdentity = identity
            try verifySocket(at: socketPath, matching: identity)
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
            listenerGeneration &+= 1
            let generation = listenerGeneration
            resolvedSocketPath = socketPath
            resolvedSocketIdentity = boundIdentity
            stateLock.unlock()

            acceptGroup.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                acceptConnections(on: descriptor, generation: generation)
                acceptGroup.leave()
            }
        } catch {
            Darwin.close(descriptor)
            if let boundIdentity {
                try? removeOwnedSocket(at: socketPath, matching: boundIdentity)
            }
            throw error
        }
    }

    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        stateLock.lock()
        let descriptor = listener
        listener = -1
        let socketPath = resolvedSocketPath
        resolvedSocketPath = nil
        let socketIdentity = resolvedSocketIdentity
        resolvedSocketIdentity = nil
        let activeClients = Array(clients.values)
        clients.removeAll()
        stateLock.unlock()

        for client in activeClients {
            client.close()
        }
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            acceptGroup.wait()
        }
        if let socketPath, let socketIdentity {
            try? removeOwnedSocket(at: socketPath, matching: socketIdentity)
        }
    }

    private func acceptConnections(on descriptor: Int32, generation: UInt64) {
        while isCurrentListener(descriptor, generation: generation) {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            do {
                try SocketDescriptor.preventSIGPIPE(client)
                try SocketDescriptor.setNonBlocking(client)
            } catch {
                Darwin.close(client)
                continue
            }
            let ownedClient = OwnedSocketDescriptor(client)
            guard register(ownedClient, for: descriptor, generation: generation) else {
                ownedClient.close()
                return
            }
            Task.detached { [self] in
                await process(ownedClient, generation: generation)
            }
        }
    }

    private func process(_ client: OwnedSocketDescriptor, generation: UInt64) async {
        defer { finishClient(client) }
        do {
            let acceptedPeerUID = try client.withDescriptor { try peerUID($0) }
            guard acceptedPeerUID == currentUID() else {
                throw RecorderControlSocketError.peerUIDMismatch
            }
            let deadline = SocketDeadline(timeout: clientTimeout)
            let requestFrame = try SocketDescriptor.readFrame(
                from: client,
                deadline: deadline
            )
            let request: RecorderControlRequest
            do {
                request = try JSONDecoder().decode(RecorderControlRequest.self, from: requestFrame)
            } catch {
                throw RecorderControlSocketError.malformedFrame
            }
            guard isActive(client, generation: generation) else {
                throw RecorderControlSocketError.connectionClosed
            }
            let response = await handler(request)
            let responseFrame = try SocketFrame.encode(response)
            try SocketDescriptor.write(responseFrame, to: client, deadline: deadline)
        } catch {
            return
        }
    }

    private func finishClient(_ client: OwnedSocketDescriptor) {
        beforeFinishedClientClose()
        client.close()
        stateLock.lock()
        clients.removeValue(forKey: ObjectIdentifier(client))
        stateLock.unlock()
    }

    private func isCurrentListener(_ descriptor: Int32, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listener == descriptor && listenerGeneration == generation
    }

    private func register(
        _ client: OwnedSocketDescriptor,
        for descriptor: Int32,
        generation: UInt64
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard listener == descriptor, listenerGeneration == generation else { return false }
        clients[ObjectIdentifier(client)] = client
        return true
    }

    private func isActive(_ client: OwnedSocketDescriptor, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listener >= 0
            && listenerGeneration == generation
            && clients[ObjectIdentifier(client)] != nil
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
        matching identity: SocketIdentity
    ) throws {
        beforeOwnedCleanup()
        var metadata = stat()
        guard lstat(socketPath, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw SocketDescriptor.posixError()
        }
        guard metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_uid == currentUID(),
              identity == SocketIdentity(metadata: metadata) else {
            return
        }
        // The private 0700 directory and same-UID peer check define the trust boundary.
        guard unlink(socketPath) == 0 else { throw SocketDescriptor.posixError() }
    }

    private func verifySocket(at socketPath: String, matching identity: SocketIdentity) throws {
        var metadata = stat()
        guard lstat(socketPath, &metadata) == 0 else {
            throw SocketDescriptor.posixError()
        }
        guard metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_uid == currentUID(),
              identity == SocketIdentity(metadata: metadata) else {
            throw RecorderControlSocketError.invalidExistingSocket
        }
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

struct SocketIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
    }

    static func readBoundSocket(
        from descriptor: Int32,
        at path: String,
        ownedBy userID: uid_t
    ) throws -> SocketIdentity {
        var descriptorMetadata = stat()
        guard fstat(descriptor, &descriptorMetadata) == 0 else {
            throw SocketDescriptor.posixError()
        }
        guard descriptorMetadata.st_mode & S_IFMT == S_IFSOCK,
              descriptorMetadata.st_uid == userID else {
            throw RecorderControlSocketError.invalidExistingSocket
        }

        // Darwin socket-descriptor inodes are not the bound filesystem node's inode.
        // The private parent directory makes UID the boundary while this path identity
        // is recorded for exact cleanup.
        var pathMetadata = stat()
        guard lstat(path, &pathMetadata) == 0 else {
            throw SocketDescriptor.posixError()
        }
        guard pathMetadata.st_mode & S_IFMT == S_IFSOCK,
              pathMetadata.st_uid == userID else {
            throw RecorderControlSocketError.invalidExistingSocket
        }
        return SocketIdentity(metadata: pathMetadata)
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

private final class OwnedSocketDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    func withDescriptor<Result>(_ body: (Int32) throws -> Result) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else {
            throw RecorderControlSocketError.connectionClosed
        }
        return try body(descriptor)
    }

    func snapshot() throws -> Int32 {
        try withDescriptor { $0 }
    }

    func validate(_ candidate: Int32) throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor == candidate else {
            throw RecorderControlSocketError.connectionClosed
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else { return }
        self.descriptor = nil
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
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

    static func wait(
        _ owner: OwnedSocketDescriptor,
        events: Int16,
        deadline: SocketDeadline
    ) throws {
        while true {
            let descriptor = try owner.snapshot()
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, deadline.remainingMilliseconds)
            try owner.validate(descriptor)
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

    static func readFrame(
        from owner: OwnedSocketDescriptor,
        deadline: SocketDeadline
    ) throws -> Data {
        var frame = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while frame.count < RecorderControlSocketServer.maximumFrameSize {
            try wait(owner, events: Int16(POLLIN), deadline: deadline)
            let capacity = min(
                buffer.count,
                RecorderControlSocketServer.maximumFrameSize - frame.count
            )
            let count = try owner.withDescriptor {
                Darwin.read($0, &buffer, capacity)
            }
            if count > 0 {
                frame.append(buffer, count: count)
                if let newline = frame.firstIndex(of: 0x0A) {
                    return frame.prefix(upTo: newline)
                }
                continue
            }
            if count == 0 { throw RecorderControlSocketError.connectionClosed }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
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

    static func write(
        _ data: Data,
        to owner: OwnedSocketDescriptor,
        deadline: SocketDeadline
    ) throws {
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while offset < data.count {
                try wait(owner, events: Int16(POLLOUT), deadline: deadline)
                let count = try owner.withDescriptor {
                    Darwin.write(
                        $0,
                        baseAddress.advanced(by: offset),
                        data.count - offset
                    )
                }
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                throw posixError()
            }
        }
    }

    static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
