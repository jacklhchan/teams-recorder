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
