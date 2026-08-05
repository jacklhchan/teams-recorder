import Darwin
import Foundation
import XCTest
@testable import RecorderControl

final class UnixSocketTransportTests: XCTestCase {
    func testOneRequestReceivesOneResponseWithMatchingID() async throws {
        let fixture = try SocketFixture()
        defer { fixture.stop() }
        let server = RecorderControlSocketServer(
            socketPath: fixture.socketPath,
            handler: { request in
                RecorderControlResponse(
                    protocolVersion: RecorderControlRequest.currentProtocolVersion,
                    requestID: request.requestID,
                    ok: true,
                    status: nil,
                    error: nil
                )
            }
        )
        fixture.server = server
        try server.start()
        let request = RecorderControlRequest(requestID: "echo-1", command: .status)

        let response = try await RecorderControlSocketClient().send(
            request,
            to: fixture.socketPath,
            timeout: 1
        )

        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertTrue(response.ok)
    }

    func testOversizedRequestFrameIsRejected() async throws {
        let fixture = try SocketFixture()
        defer { fixture.stop() }
        let server = RecorderControlSocketServer(
            socketPath: fixture.socketPath,
            handler: { request in
                RecorderControlResponse(
                    protocolVersion: RecorderControlRequest.currentProtocolVersion,
                    requestID: request.requestID,
                    ok: true,
                    status: nil,
                    error: nil
                )
            }
        )
        fixture.server = server
        try server.start()
        let request = RecorderControlRequest(
            requestID: "oversized",
            command: .setMic,
            argument: String(repeating: "x", count: RecorderControlSocketServer.maximumFrameSize)
        )

        do {
            _ = try await RecorderControlSocketClient().send(
                request,
                to: fixture.socketPath,
                timeout: 1
            )
            XCTFail("Expected an oversized frame error")
        } catch {
            XCTAssertEqual(error as? RecorderControlSocketError, .oversizedFrame)
        }
    }

    func testStopRemovesSocket() throws {
        let fixture = try SocketFixture()
        defer { fixture.stop() }
        let server = RecorderControlSocketServer(
            socketPath: fixture.socketPath,
            handler: { request in
                RecorderControlResponse(
                    protocolVersion: RecorderControlRequest.currentProtocolVersion,
                    requestID: request.requestID,
                    ok: true,
                    status: nil,
                    error: nil
                )
            }
        )
        fixture.server = server
        try server.start()

        server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketPath))
    }

    func testPeerUIDMismatchRejectsRequest() async throws {
        let fixture = try SocketFixture()
        defer { fixture.stop() }
        let userID = getuid()
        let handlerProbe = PeerHandlerProbe()
        let server = RecorderControlSocketServer(
            socketPath: fixture.socketPath,
            currentUID: { userID },
            peerUID: { _ in userID &+ 1 },
            handler: { request in
                await handlerProbe.recordRequest()
                return RecorderControlResponse(
                    protocolVersion: RecorderControlRequest.currentProtocolVersion,
                    requestID: request.requestID,
                    ok: true,
                    status: nil,
                    error: nil
                )
            }
        )
        fixture.server = server
        try server.start()

        do {
            _ = try await RecorderControlSocketClient().send(
                .init(requestID: "wrong-user", command: .status),
                to: fixture.socketPath,
                timeout: 1
            )
            XCTFail("Expected the wrong-user peer to be rejected")
        } catch {}
        let handledRequestCount = await handlerProbe.requestCount
        XCTAssertEqual(handledRequestCount, 0)
    }

    func testSlowClientIsClosedAtServerDeadline() throws {
        let fixture = try SocketFixture()
        defer { fixture.stop() }
        let server = RecorderControlSocketServer(
            socketPath: fixture.socketPath,
            requestTimeout: 0.05,
            handler: { request in
                RecorderControlResponse(
                    protocolVersion: RecorderControlRequest.currentProtocolVersion,
                    requestID: request.requestID,
                    ok: true,
                    status: nil,
                    error: nil
                )
            }
        )
        fixture.server = server
        try server.start()
        let client = try makeConnectedSocket(path: fixture.socketPath)
        defer { Darwin.close(client) }
        var partialFrame: UInt8 = 0x7B
        XCTAssertEqual(Darwin.write(client, &partialFrame, 1), 1)

        var item = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(Darwin.poll(&item, 1, 1_000), 1)
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(client, &byte, 1), 0)
    }

    func testStopClosesAcceptedClientDescriptorBeforeReturning() throws {
        let fixture = try SocketFixture()
        defer { fixture.stop() }
        let accepted = AcceptedDescriptorProbe()
        let server = RecorderControlSocketServer(
            socketPath: fixture.socketPath,
            peerUID: { descriptor in
                accepted.capture(descriptor)
                return getuid()
            },
            handler: { request in
                RecorderControlResponse(
                    protocolVersion: RecorderControlRequest.currentProtocolVersion,
                    requestID: request.requestID,
                    ok: true,
                    status: nil,
                    error: nil
                )
            }
        )
        fixture.server = server
        try server.start()
        let client = try makeConnectedSocket(path: fixture.socketPath)
        defer { Darwin.close(client) }
        let descriptor = try XCTUnwrap(accepted.waitForDescriptor())

        server.stop()

        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testStopClosesClientBeforeFinishedClientLeavesRegistry() async throws {
        let fixture = try SocketFixture()
        defer { fixture.stop() }
        let accepted = AcceptedDescriptorProbe()
        let finish = FinishedClientCloseProbe()
        defer { finish.releaseClose() }
        let server = RecorderControlSocketServer(
            socketPath: fixture.socketPath,
            peerUID: { descriptor in
                accepted.capture(descriptor)
                return getuid()
            },
            beforeFinishedClientClose: { finish.beforeClose() },
            handler: { request in
                RecorderControlResponse(
                    protocolVersion: RecorderControlRequest.currentProtocolVersion,
                    requestID: request.requestID,
                    ok: true,
                    status: nil,
                    error: nil
                )
            }
        )
        fixture.server = server
        try server.start()

        _ = try await RecorderControlSocketClient().send(
            .init(requestID: "finish-order", command: .status),
            to: fixture.socketPath,
            timeout: 1
        )
        let descriptor = try XCTUnwrap(accepted.waitForDescriptor())
        XCTAssertTrue(finish.waitForClose())

        server.stop()

        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testConcurrentStartsAreSerialized() throws {
        let fixture = try SocketFixture()
        defer { fixture.stop() }
        let probe = ConcurrentStartProbe()
        let server = RecorderControlSocketServer(
            socketPath: fixture.socketPath,
            beforeBind: { probe.beforeBind() },
            handler: { request in
                RecorderControlResponse(
                    protocolVersion: RecorderControlRequest.currentProtocolVersion,
                    requestID: request.requestID,
                    ok: true,
                    status: nil,
                    error: nil
                )
            }
        )
        fixture.server = server
        let first = DispatchQueue.global().asyncResult { try server.start() }
        XCTAssertTrue(probe.waitForFirstStart())
        let second = DispatchQueue.global().asyncResult { try server.start() }
        probe.waitForSecondStartOrTimeout()
        probe.releaseFirstStart()

        XCTAssertNoThrow(try first.get().get())
        XCTAssertNoThrow(try second.get().get())
    }

    func testStartWaitsForStopCleanup() throws {
        let fixture = try SocketFixture()
        defer { fixture.stop() }
        let probe = StopCleanupProbe()
        let server = RecorderControlSocketServer(
            socketPath: fixture.socketPath,
            beforeOwnedCleanup: { probe.beforeCleanup() },
            handler: { request in
                RecorderControlResponse(
                    protocolVersion: RecorderControlRequest.currentProtocolVersion,
                    requestID: request.requestID,
                    ok: true,
                    status: nil,
                    error: nil
                )
            }
        )
        fixture.server = server
        try server.start()
        let stop = DispatchQueue.global().asyncResult { server.stop() }
        XCTAssertTrue(probe.waitForCleanup())
        let start = DispatchQueue.global().asyncResult { try server.start() }

        XCTAssertFalse(start.wait(timeout: 0.1))
        probe.releaseCleanup()
        _ = stop.get()
        XCTAssertNoThrow(try start.get().get())
    }

    func testFailedStartDoesNotRemoveReplacementWhenPathDiffersFromBoundDescriptor() throws {
        let fixture = try SocketFixture()
        defer { fixture.stop() }
        let replacement = ReplacementServerHolder()
        let server = RecorderControlSocketServer(
            socketPath: fixture.socketPath,
            socketIdentityProvider: { descriptor, path, userID in
                let identity = try SocketIdentity.readBoundSocket(
                    from: descriptor,
                    at: path,
                    ownedBy: userID
                )
                XCTAssertEqual(unlink(fixture.socketPath), 0)
                let replacementServer = RecorderControlSocketServer(
                    socketPath: fixture.socketPath,
                    handler: { request in
                        RecorderControlResponse(
                            protocolVersion: RecorderControlRequest.currentProtocolVersion,
                            requestID: request.requestID,
                            ok: true,
                            status: nil,
                            error: nil
                        )
                    }
                )
                replacement.server = replacementServer
                try replacementServer.start()
                return identity
            },
            handler: { request in
                RecorderControlResponse(
                    protocolVersion: RecorderControlRequest.currentProtocolVersion,
                    requestID: request.requestID,
                    ok: true,
                    status: nil,
                    error: nil
                )
            }
        )
        defer { replacement.server?.stop() }

        XCTAssertThrowsError(try server.start())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.socketPath))
    }
}

private final class AcceptedDescriptorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var descriptor: Int32?

    func capture(_ descriptor: Int32) {
        lock.lock()
        self.descriptor = descriptor
        lock.unlock()
        ready.signal()
    }

    func waitForDescriptor() -> Int32? {
        guard ready.wait(timeout: .now() + 1) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }
}

private final class FinishedClientCloseProbe: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func beforeClose() {
        entered.signal()
        release.wait()
    }

    func waitForClose() -> Bool {
        entered.wait(timeout: .now() + 1) == .success
    }

    func releaseClose() {
        release.signal()
    }
}

private final class ConcurrentStartProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let firstStarted = DispatchSemaphore(value: 0)
    private let secondStarted = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private var count = 0

    func beforeBind() {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        if current == 1 {
            firstStarted.signal()
            releaseFirst.wait()
        } else {
            secondStarted.signal()
        }
    }

    func waitForFirstStart() -> Bool {
        firstStarted.wait(timeout: .now() + 1) == .success
    }

    func waitForSecondStartOrTimeout() {
        _ = secondStarted.wait(timeout: .now() + 0.1)
    }

    func releaseFirstStart() {
        releaseFirst.signal()
    }
}

private final class StopCleanupProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var didBlock = false

    func beforeCleanup() {
        lock.lock()
        guard !didBlock else {
            lock.unlock()
            return
        }
        didBlock = true
        lock.unlock()
        entered.signal()
        release.wait()
    }

    func waitForCleanup() -> Bool {
        entered.wait(timeout: .now() + 1) == .success
    }

    func releaseCleanup() {
        release.signal()
    }
}

private final class ReplacementServerHolder: @unchecked Sendable {
    var server: RecorderControlSocketServer?
}

private final class AsyncResult<Value>: @unchecked Sendable {
    private let ready = DispatchGroup()
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    init() {
        ready.enter()
    }

    func complete(_ body: () throws -> Value) {
        let result = Result(catching: body)
        lock.lock()
        self.result = result
        lock.unlock()
        ready.leave()
    }

    func wait(timeout: TimeInterval) -> Bool {
        ready.wait(timeout: .now() + timeout) == .success
    }

    func get() -> Result<Value, Error> {
        ready.wait()
        lock.lock()
        defer { lock.unlock() }
        return result!
    }
}

private extension DispatchQueue {
    func asyncResult<Value>(_ body: @escaping @Sendable () throws -> Value) -> AsyncResult<Value> {
        let result = AsyncResult<Value>()
        async { result.complete(body) }
        return result
    }
}

private func makeConnectedSocket(path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    do {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        let length = MemoryLayout.offset(of: \sockaddr_un.sun_path)! + bytes.count + 1
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { target in
                for (index, byte) in bytes.enumerated() { target[index] = byte }
                target[bytes.count] = 0
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(length))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    } catch {
        Darwin.close(descriptor)
        throw error
    }
}

private actor PeerHandlerProbe {
    private(set) var requestCount = 0

    func recordRequest() {
        requestCount += 1
    }
}

private final class SocketFixture {
    let directory: URL
    let socketPath: String
    var server: RecorderControlSocketServer?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lmr-sock-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("control.sock").path
    }

    func stop() {
        server?.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}
