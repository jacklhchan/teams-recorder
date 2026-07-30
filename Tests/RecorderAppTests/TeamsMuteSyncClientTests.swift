import Foundation
import XCTest
@testable import RecorderApp

final class TeamsMuteSyncClientTests: XCTestCase {
    private let reconnectDelay: Duration = .seconds(20)
    private let heartbeatInterval: Duration = .seconds(30)
    private let pingTimeout: Duration = .seconds(40)

    func testPingWaiterCancellationCompletesWithoutPongCallback() async {
        let callbackStore = TeamsPingCallbackStore()
        let callbackInstalled = DispatchSemaphore(value: 0)
        let waiter = TeamsWebSocketPingWaiter()
        let task = Task {
            try await waiter.wait { callback in
                callbackStore.store(callback)
                callbackInstalled.signal()
            }
        }
        XCTAssertEqual(
            callbackInstalled.wait(timeout: .now() + 1),
            .success
        )

        task.cancel()

        do {
            try await task.value
            XCTFail("Cancelled ping wait unexpectedly succeeded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        callbackStore.finish(error: nil)
    }

    func testHeartbeatPingFailureCancelsPendingReceiveAndReconnectsAfterDelay() async {
        let first = ScriptedTeamsWebSocketConnection()
        first.enqueuePingFailure(.pingFailed)
        let second = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([first, second])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore(token: "paired-token")
        let events = TeamsEventRecorder()
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )

        client.start(onEvent: events.record)
        await assertEventually {
            first.sentActions == ["query-state"]
                && first.pendingReceiveCount == 1
                && sleeper.pendingCount(for: self.heartbeatInterval) == 1
        }

        XCTAssertTrue(sleeper.resumeNext(for: heartbeatInterval))
        await assertEventually {
            first.cancelCount > 0
                && first.pendingReceiveCount == 0
                && sleeper.pendingCount(for: self.reconnectDelay) == 1
        }
        XCTAssertEqual(factory.createdCount, 1)

        XCTAssertTrue(sleeper.resumeNext(for: reconnectDelay))
        await assertEventually {
            factory.createdCount == 2
                && second.resumeCount == 1
                && second.sentActions == ["query-state"]
        }

        client.stop()
    }

    func testHeartbeatPingTimeoutCancelsPendingPingAndReceiveThenReconnects() async {
        let first = ScriptedTeamsWebSocketConnection(
            releasesPingOnCancel: false
        )
        let second = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([first, second])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore(token: "paired-token")
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )

        client.start { _ in }
        await assertEventually {
            first.sentActions == ["query-state"]
                && first.pendingReceiveCount == 1
                && sleeper.pendingCount(for: self.heartbeatInterval) == 1
        }

        XCTAssertTrue(sleeper.resumeNext(for: heartbeatInterval))
        await assertEventually {
            first.pendingPingCount == 1
                && sleeper.pendingCount(for: self.pingTimeout) == 1
        }

        XCTAssertTrue(sleeper.resumeNext(for: pingTimeout))
        await assertEventually {
            first.cancelCount > 0
                && first.pendingPingCount == 1
                && first.pendingReceiveCount == 0
                && sleeper.pendingCount(for: self.reconnectDelay) == 1
        }

        XCTAssertTrue(sleeper.resumeNext(for: reconnectDelay))
        await assertEventually {
            factory.createdCount == 2
                && second.sentActions == ["query-state"]
        }

        first.releasePendingPings()
        await assertEventually { first.pendingPingCount == 0 }
        client.stop()
    }

    func testReconnectCannotLetAnOlderUnmuteArriveAfterNewFailClosedStatus() async {
        let first = ScriptedTeamsWebSocketConnection()
        let second = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([first, second])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore(token: "paired-token")
        let gate = MicrophoneMuteGate { _ in }
        let relay = TeamsMuteRelay(microphoneMuteGate: gate)
        let relayGeneration = relay.enable()
        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let reconnectStarted = DispatchSemaphore(value: 0)
        let reconnectCompleted = ThreadSafeTeamsFlag()
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )

        client.start { event in
            if case .meetingState(let state) = event,
               state.isInMeeting,
               !state.isMuted {
                callbackEntered.signal()
                releaseCallback.wait()
            }
            _ = relay.apply(event, generation: relayGeneration)
        }
        await assertEventually { first.sentActions == ["query-state"] }
        first.pushIncoming(Self.mutedMeetingMessage)
        await assertEventually { gate.snapshot.effectiveMuted }

        first.pushIncoming(Self.unmutedMeetingMessage)
        XCTAssertEqual(
            callbackEntered.wait(timeout: .now() + 1),
            .success
        )
        DispatchQueue.global().async {
            reconnectStarted.signal()
            client.reconnect()
            reconnectCompleted.set()
        }
        XCTAssertEqual(
            reconnectStarted.wait(timeout: .now() + 1),
            .success
        )
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(reconnectCompleted.value)

        releaseCallback.signal()
        await assertEventually {
            reconnectCompleted.value
                && factory.createdCount == 2
                && gate.snapshot.effectiveMuted
        }
        client.stop()
    }

    func testInvalidTokenReconnectsImmediatelyWithoutReconnectSleep() async {
        let first = ScriptedTeamsWebSocketConnection()
        let second = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([first, second])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore(token: "stale-token")
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )

        client.start { _ in }
        await assertEventually {
            first.sentActions == ["query-state"]
                && first.pendingReceiveCount == 1
        }

        first.pushIncoming(#"{"errorMsg":"Invalid token"}"#)
        await assertEventually {
            factory.createdCount == 2
                && second.sentActions == ["query-state"]
        }

        XCTAssertNil(try? tokenStore.load())
        XCTAssertEqual(tokenStore.clearCount, 1)
        XCTAssertEqual(sleeper.requestCount(for: reconnectDelay), 0)
        XCTAssertFalse(factory.createdURLs[1].queryItems.contains("token"))

        client.stop()
    }

    func testGenericServerErrorRedactsServerControlledMessage() async {
        let socket = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([socket])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore(token: "paired-token")
        let events = TeamsEventRecorder()
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )
        let sentinel = "C3_SECRET_SENTINEL_6E41A9"

        client.start(onEvent: events.record)
        await assertEventually { socket.sentActions == ["query-state"] }

        socket.pushIncoming(#"{"errorMsg":"generic failure: C3_SECRET_SENTINEL_6E41A9"}"#)
        await assertEventually {
            events.events.contains(
                .status(.failed("Teams API reported an error."))
            )
        }

        XCTAssertFalse(events.events.description.contains(sentinel))
        client.stop()
    }

    func testDeviceAlreadyPairedEmitsRecoverableStatusAndAllowsOneExplicitRetry() async {
        let socket = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([socket])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore()
        let events = TeamsEventRecorder()
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )

        client.start(onEvent: events.record)
        await assertEventually { socket.sentActions == ["query-state"] }

        socket.pushIncoming(Self.canPairMessage)
        await assertEventually { socket.sentActions == ["query-state", "pair"] }

        socket.pushIncoming(
            #"{"requestId":2,"response":"Device already paired"}"#
        )
        await assertEventually {
            events.events.contains(.status(.pairingResetRequired))
        }

        socket.pushIncoming(Self.canPairMessage)
        socket.pushIncoming(Self.canPairMessage)
        await settle()
        XCTAssertEqual(socket.sentActions, ["query-state", "pair"])

        client.requestPairing()
        await assertEventually {
            socket.sentActions == ["query-state", "pair", "pair"]
        }
        client.requestPairing()
        await settle()
        XCTAssertEqual(socket.sentActions, ["query-state", "pair", "pair"])

        client.stop()
    }

    func testNoActionRequiresExplicitRetryAndDoesNotPromptLoop() async {
        let socket = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([socket])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore()
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )

        client.start { _ in }
        await assertEventually { socket.sentActions == ["query-state"] }

        socket.pushIncoming(Self.canPairMessage)
        await assertEventually { socket.sentActions == ["query-state", "pair"] }
        socket.pushIncoming(
            #"{"requestId":2,"response":"Pairing response resulted in no action"}"#
        )
        socket.pushIncoming(Self.canPairMessage)
        socket.pushIncoming(Self.canPairMessage)
        await settle()
        XCTAssertEqual(socket.sentActions, ["query-state", "pair"])

        client.requestPairing()
        await assertEventually {
            socket.sentActions == ["query-state", "pair", "pair"]
        }
        client.requestPairing()
        await settle()
        XCTAssertEqual(socket.sentActions, ["query-state", "pair", "pair"])

        client.stop()
    }

    func testPairingUpdateStillEmitsAbsoluteMeetingStateBeforeApproval() async {
        let socket = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([socket])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore()
        let events = TeamsEventRecorder()
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )

        client.start(onEvent: events.record)
        await assertEventually { socket.sentActions == ["query-state"] }

        socket.pushIncoming(Self.mutedPairingMeetingMessage)
        await assertEventually {
            socket.sentActions == ["query-state", "pair"]
                && events.events.contains(
                    .meetingState(
                        TeamsMeetingState(
                            isInMeeting: true,
                            isMuted: true,
                            canToggleMute: false,
                            canPair: true
                        )
                    )
                )
        }

        client.stop()
    }

    func testUnpairedRestrictedUpdateStillEmitsAbsoluteMeetingMuteState() async {
        let socket = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([socket])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore()
        let events = TeamsEventRecorder()
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )

        client.start(onEvent: events.record)
        await assertEventually { socket.sentActions == ["query-state"] }

        socket.pushIncoming(Self.mutedRestrictedMeetingMessage)
        await assertEventually {
            events.events.contains(
                .meetingState(
                    TeamsMeetingState(
                        isInMeeting: true,
                        isMuted: true,
                        canToggleMute: false,
                        canPair: false
                    )
                )
            )
        }

        XCTAssertEqual(events.events.last, .status(.waitingForMeeting))
        client.stop()
    }

    func testUnpairedOutOfMeetingStateDoesNotClaimReadyPairing() async {
        let socket = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([socket])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore()
        let events = TeamsEventRecorder()
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )

        client.start(onEvent: events.record)
        await assertEventually { socket.sentActions == ["query-state"] }

        socket.pushIncoming(Self.unpairedOutOfMeetingMessage)
        await assertEventually {
            events.events.contains(
                .meetingState(
                    TeamsMeetingState(
                        isInMeeting: false,
                        isMuted: false,
                        canToggleMute: false,
                        canPair: false
                    )
                )
            )
        }

        XCTAssertEqual(events.events.last, .status(.waitingForMeeting))
        client.stop()
    }

    func testStalePairingResponseCannotRegressReadyStateAfterTokenRefresh() async {
        let socket = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([socket])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore()
        let events = TeamsEventRecorder()
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )

        client.start(onEvent: events.record)
        await assertEventually { socket.sentActions == ["query-state"] }
        socket.pushIncoming(Self.canPairMessage)
        await assertEventually {
            socket.sentActions == ["query-state", "pair"]
        }

        socket.pushIncoming(#"{"tokenRefresh":"fresh-token"}"#)
        await assertEventually {
            socket.sentActions == ["query-state", "pair", "query-state"]
                && events.events.last == .status(.ready)
        }

        socket.pushIncoming(
            #"{"requestId":2,"response":"Pairing response resulted in no action"}"#
        )
        await settle()

        XCTAssertEqual(events.events.last, .status(.ready))
        client.stop()
    }

    func testManualPairingSendFailureCancelsSocketAndReconnectsImmediately() async {
        let first = ScriptedTeamsWebSocketConnection()
        first.enqueueSendSuccess()
        first.enqueueSendFailure(.sendFailed)
        let second = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([first, second])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore()
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )

        client.start { _ in }
        await assertEventually {
            first.sentActions == ["query-state"]
                && first.pendingReceiveCount == 1
        }

        client.requestPairing()
        await assertEventually {
            first.sentActions == ["query-state", "pair"]
                && first.cancelCount > 0
                && factory.createdCount == 2
                && second.sentActions == ["query-state"]
        }

        XCTAssertEqual(sleeper.requestCount(for: reconnectDelay), 0)
        client.stop()
    }

    func testReconnectAndStopSuppressEventsFromStaleGenerations() async {
        let first = ScriptedTeamsWebSocketConnection(
            releasesReceiveOnCancel: false
        )
        let second = ScriptedTeamsWebSocketConnection(
            releasesReceiveOnCancel: false
        )
        let factory = ScriptedTeamsWebSocketFactory([first, second])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore(token: "paired-token")
        let events = TeamsEventRecorder()
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )

        client.start(onEvent: events.record)
        await assertEventually {
            first.sentActions == ["query-state"]
                && first.pendingReceiveCount == 1
        }

        client.reconnect()
        await assertEventually {
            factory.createdCount == 2
                && second.sentActions == ["query-state"]
                && second.pendingReceiveCount == 1
        }

        first.pushIncoming(Self.mutedMeetingMessage)
        await settle()
        XCTAssertFalse(events.events.contains { event in
            if case .meetingState = event { return true }
            return false
        })

        client.stop()
        second.pushIncoming(Self.mutedMeetingMessage)
        await settle()
        XCTAssertFalse(events.events.contains { event in
            if case .meetingState = event { return true }
            return false
        })
        XCTAssertEqual(factory.createdCount, 2)
    }

    func testReconnectRejectsTokenRefreshFromStaleConnection() async {
        let first = ScriptedTeamsWebSocketConnection(
            releasesReceiveOnCancel: false
        )
        let second = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([first, second])
        let sleeper = ManualTeamsSleeper()
        let tokenStore = InMemoryTeamsPairingTokenStore(token: "current-token")
        let client = makeClient(
            tokenStore: tokenStore,
            factory: factory,
            sleeper: sleeper
        )

        client.start { _ in }
        await assertEventually {
            first.sentActions == ["query-state"]
                && first.pendingReceiveCount == 1
        }
        client.reconnect()
        await assertEventually {
            second.sentActions == ["query-state"]
                && second.pendingReceiveCount == 1
        }

        first.pushIncoming(#"{"tokenRefresh":"stale-token"}"#)
        await settle()

        XCTAssertEqual(try? tokenStore.load(), "current-token")
        client.stop()
    }

    func testCredentialLoadFailureDoesNotCreateSocket() async {
        let store = InMemoryTeamsPairingTokenStore()
        store.loadError = ScriptedTeamsError.storageFailed
        let socket = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([socket])
        let sleeper = ManualTeamsSleeper()
        let events = TeamsEventRecorder()
        let client = makeClient(
            tokenStore: store,
            factory: factory,
            sleeper: sleeper
        )

        client.start(onEvent: events.record)
        await assertEventually {
            events.events.contains {
                guard case .status(.failed(let message)) = $0 else {
                    return false
                }
                return message.contains("Keychain")
            }
        }

        XCTAssertEqual(factory.createdCount, 0)
    }

    func testTokenRefreshSaveFailureNeverReportsReady() async {
        let store = InMemoryTeamsPairingTokenStore()
        store.saveError = ScriptedTeamsError.storageFailed
        let socket = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([socket])
        let sleeper = ManualTeamsSleeper()
        let events = TeamsEventRecorder()
        let client = makeClient(
            tokenStore: store,
            factory: factory,
            sleeper: sleeper
        )

        client.start(onEvent: events.record)
        await assertEventually { socket.sentActions == ["query-state"] }
        socket.pushIncoming(#"{"tokenRefresh":"secret-value"}"#)
        await assertEventually {
            events.events.contains {
                guard case .status(.failed(let message)) = $0 else {
                    return false
                }
                return message.contains("Keychain")
            }
        }

        XCTAssertFalse(events.events.contains(.status(.ready)))
        XCTAssertFalse(events.events.description.contains("secret-value"))
        XCTAssertGreaterThan(socket.cancelCount, 0)
    }

    func testInvalidTokenClearFailureStopsAutomaticReconnect() async {
        let store = InMemoryTeamsPairingTokenStore(token: "stale")
        store.clearError = ScriptedTeamsError.storageFailed
        let socket = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([socket])
        let sleeper = ManualTeamsSleeper()
        let events = TeamsEventRecorder()
        let client = makeClient(
            tokenStore: store,
            factory: factory,
            sleeper: sleeper
        )

        client.start(onEvent: events.record)
        await assertEventually { socket.sentActions == ["query-state"] }
        socket.pushIncoming(#"{"errorMsg":"Invalid token"}"#)
        await assertEventually {
            events.events.contains {
                guard case .status(.failed(let message)) = $0 else {
                    return false
                }
                return message.contains("Keychain")
            }
        }
        await settle()

        XCTAssertEqual(factory.createdCount, 1)
        XCTAssertGreaterThan(socket.cancelCount, 0)
    }

    func testReconnectCannotAdvanceGenerationDuringTokenSave() async {
        let store = BlockingTeamsPairingTokenStore(token: nil)
        let first = ScriptedTeamsWebSocketConnection()
        let second = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([first, second])
        let sleeper = ManualTeamsSleeper()
        let client = makeClient(
            tokenStore: store,
            factory: factory,
            sleeper: sleeper
        )

        client.start { _ in }
        await assertEventually { first.sentActions == ["query-state"] }
        first.pushIncoming(#"{"tokenRefresh":"fresh-token"}"#)
        await store.waitUntilSaveStarts()

        let reconnect = Task { client.reconnect() }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(factory.createdCount, 1)

        store.allowSaveToFinish()
        await reconnect.value
        await assertEventually { factory.createdCount == 2 }
        XCTAssertEqual(try? store.load(), "fresh-token")
        client.stop()
    }

    func testReconnectCannotAdvanceGenerationDuringTokenClear() async {
        let store = BlockingTeamsPairingTokenStore(token: "stale")
        let first = ScriptedTeamsWebSocketConnection()
        let second = ScriptedTeamsWebSocketConnection()
        // The invalid-token loop and explicit reconnect may each win the
        // post-clear race, so both valid schedules need a scripted socket.
        let third = ScriptedTeamsWebSocketConnection()
        let factory = ScriptedTeamsWebSocketFactory([first, second, third])
        let sleeper = ManualTeamsSleeper()
        let client = makeClient(
            tokenStore: store,
            factory: factory,
            sleeper: sleeper
        )

        client.start { _ in }
        await assertEventually { first.sentActions == ["query-state"] }
        first.pushIncoming(#"{"errorMsg":"Invalid token"}"#)
        await store.waitUntilClearStarts()

        let reconnect = Task { client.reconnect() }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(factory.createdCount, 1)

        store.allowClearToFinish()
        await reconnect.value
        await assertEventually { factory.createdCount >= 2 }
        XCTAssertNil(try? store.load())
        client.stop()
    }

    private func makeClient(
        tokenStore: any TeamsPairingTokenStoring,
        factory: ScriptedTeamsWebSocketFactory,
        sleeper: ManualTeamsSleeper
    ) -> TeamsMuteSyncClient {
        TeamsMuteSyncClient(
            identity: .recorder(appVersion: "tests"),
            tokenStore: tokenStore,
            reconnectDelay: reconnectDelay,
            heartbeatInterval: heartbeatInterval,
            pingTimeout: pingTimeout,
            connectionFactory: { url in
                factory.makeConnection(url)
            },
            sleep: { duration in
                try await sleeper.sleep(for: duration)
            }
        )
    }

    private func assertEventually(
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private func settle() async {
        for _ in 0..<200 {
            await Task.yield()
        }
    }

    private static let canPairMessage =
        #"{"meetingUpdate":{"meetingPermissions":{"canPair":true}}}"#

    private static let mutedMeetingMessage =
        #"{"meetingUpdate":{"meetingState":{"isMuted":true,"isInMeeting":true},"meetingPermissions":{"canToggleMute":true,"canPair":false}}}"#

    private static let unmutedMeetingMessage =
        #"{"meetingUpdate":{"meetingState":{"isMuted":false,"isInMeeting":true},"meetingPermissions":{"canToggleMute":true,"canPair":false}}}"#

    private static let mutedPairingMeetingMessage =
        #"{"meetingUpdate":{"meetingState":{"isMuted":true,"isInMeeting":true},"meetingPermissions":{"canToggleMute":false,"canPair":true}}}"#

    private static let mutedRestrictedMeetingMessage =
        #"{"meetingUpdate":{"meetingState":{"isMuted":true,"isInMeeting":true},"meetingPermissions":{"canToggleMute":false,"canPair":false}}}"#

    private static let unpairedOutOfMeetingMessage =
        #"{"meetingUpdate":{"meetingState":{"isMuted":false,"isInMeeting":false},"meetingPermissions":{"canToggleMute":false,"canPair":false}}}"#
}

private final class ScriptedTeamsWebSocketConnection:
    TeamsWebSocketConnection,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let releasesReceiveOnCancel: Bool
    private let releasesPingOnCancel: Bool
    private var receiveResults: [
        Result<URLSessionWebSocketTask.Message, Error>
    ] = []
    private var receiveWaiters: [
        CheckedContinuation<URLSessionWebSocketTask.Message, Error>
    ] = []
    private var sendResults: [Result<Void, Error>] = []
    private var pingResults: [Result<Void, Error>] = []
    private var pingWaiters: [CheckedContinuation<Void, Error>] = []
    private var messages: [URLSessionWebSocketTask.Message] = []
    private var didCancel = false
    private var _resumeCount = 0
    private var _cancelCount = 0

    init(
        releasesReceiveOnCancel: Bool = true,
        releasesPingOnCancel: Bool = true
    ) {
        self.releasesReceiveOnCancel = releasesReceiveOnCancel
        self.releasesPingOnCancel = releasesPingOnCancel
    }

    var resumeCount: Int {
        lock.synchronized { _resumeCount }
    }

    var cancelCount: Int {
        lock.synchronized { _cancelCount }
    }

    var pendingReceiveCount: Int {
        lock.synchronized { receiveWaiters.count }
    }

    var pendingPingCount: Int {
        lock.synchronized { pingWaiters.count }
    }

    var sentActions: [String] {
        lock.synchronized { messages }.compactMap { message in
            guard case .string(let text) = message,
                  let object = try? JSONSerialization.jsonObject(
                    with: Data(text.utf8)
                  ) as? [String: Any] else {
                return nil
            }
            return object["action"] as? String
        }
    }

    func enqueueSendSuccess() {
        lock.synchronized {
            sendResults.append(.success(()))
        }
    }

    func enqueueSendFailure(_ error: ScriptedTeamsError) {
        lock.synchronized {
            sendResults.append(.failure(error))
        }
    }

    func enqueuePingFailure(_ error: ScriptedTeamsError) {
        lock.synchronized {
            pingResults.append(.failure(error))
        }
    }

    func releasePendingPings() {
        let continuations: [CheckedContinuation<Void, Error>] =
            lock.synchronized {
                let continuations = pingWaiters
                pingWaiters.removeAll()
                return continuations
            }
        continuations.forEach {
            $0.resume(throwing: ScriptedTeamsError.cancelled)
        }
    }

    func pushIncoming(_ text: String) {
        deliverReceive(.success(.string(text)))
    }

    func resume() {
        lock.synchronized {
            _resumeCount += 1
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let result: Result<Void, Error> = lock.synchronized {
            messages.append(message)
            if !sendResults.isEmpty {
                return sendResults.removeFirst()
            }
            return didCancel
                ? .failure(ScriptedTeamsError.cancelled)
                : .success(())
        }
        try result.get()
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<URLSessionWebSocketTask.Message, Error>? =
                lock.synchronized {
                    if !receiveResults.isEmpty {
                        return receiveResults.removeFirst()
                    }
                    if didCancel, releasesReceiveOnCancel {
                        return .failure(ScriptedTeamsError.cancelled)
                    }
                    receiveWaiters.append(continuation)
                    return nil
                }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Void, Error>? = lock.synchronized {
                if !pingResults.isEmpty {
                    return pingResults.removeFirst()
                }
                if didCancel {
                    return .failure(ScriptedTeamsError.cancelled)
                }
                pingWaiters.append(continuation)
                return nil
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func cancel(
        with closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let receiveContinuations: [
            CheckedContinuation<URLSessionWebSocketTask.Message, Error>
        ]
        let pingContinuations: [CheckedContinuation<Void, Error>]
        (receiveContinuations, pingContinuations) = lock.synchronized {
            _cancelCount += 1
            didCancel = true
            let receiveContinuations = releasesReceiveOnCancel
                ? receiveWaiters
                : []
            if releasesReceiveOnCancel {
                receiveWaiters.removeAll()
            }
            let pingContinuations = releasesPingOnCancel ? pingWaiters : []
            if releasesPingOnCancel {
                pingWaiters.removeAll()
            }
            return (receiveContinuations, pingContinuations)
        }
        receiveContinuations.forEach {
            $0.resume(throwing: ScriptedTeamsError.cancelled)
        }
        pingContinuations.forEach {
            $0.resume(throwing: ScriptedTeamsError.cancelled)
        }
    }

    private func deliverReceive(
        _ result: Result<URLSessionWebSocketTask.Message, Error>
    ) {
        let continuation: CheckedContinuation<
            URLSessionWebSocketTask.Message,
            Error
        >? = lock.synchronized {
            guard !receiveWaiters.isEmpty else {
                receiveResults.append(result)
                return nil
            }
            return receiveWaiters.removeFirst()
        }
        continuation?.resume(with: result)
    }
}

private final class ScriptedTeamsWebSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ScriptedTeamsWebSocketConnection]
    private var urls: [URL] = []

    init(_ connections: [ScriptedTeamsWebSocketConnection]) {
        self.connections = connections
    }

    var createdCount: Int {
        lock.synchronized { urls.count }
    }

    var createdURLs: [URL] {
        lock.synchronized { urls }
    }

    func makeConnection(_ url: URL) -> any TeamsWebSocketConnection {
        lock.synchronized {
            precondition(!connections.isEmpty, "Unexpected connection request")
            urls.append(url)
            return connections.removeFirst()
        }
    }
}

private final class ManualTeamsSleeper: @unchecked Sendable {
    private struct Waiter {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var waiters: [UUID: Waiter] = [:]
    private var order: [UUID] = []
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var requests: [Duration] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelImmediately = lock.synchronized {
                    requests.append(duration)
                    if cancelledBeforeRegistration.remove(id) != nil {
                        return true
                    }
                    waiters[id] = Waiter(
                        duration: duration,
                        continuation: continuation
                    )
                    order.append(id)
                    return false
                }
                if cancelImmediately {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    func pendingCount(for duration: Duration) -> Int {
        lock.synchronized {
            waiters.values.filter { $0.duration == duration }.count
        }
    }

    func requestCount(for duration: Duration) -> Int {
        lock.synchronized {
            requests.filter { $0 == duration }.count
        }
    }

    @discardableResult
    func resumeNext(for duration: Duration) -> Bool {
        let continuation: CheckedContinuation<Void, Error>? =
            lock.synchronized {
                guard let id = order.first(where: {
                    waiters[$0]?.duration == duration
                }), let waiter = waiters.removeValue(forKey: id) else {
                    return nil
                }
                order.removeAll { $0 == id }
                return waiter.continuation
            }
        continuation?.resume()
        return continuation != nil
    }

    private func cancel(_ id: UUID) {
        let continuation: CheckedContinuation<Void, Error>? =
            lock.synchronized {
                guard let waiter = waiters.removeValue(forKey: id) else {
                    cancelledBeforeRegistration.insert(id)
                    return nil
                }
                order.removeAll { $0 == id }
                return waiter.continuation
            }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class InMemoryTeamsPairingTokenStore:
    TeamsPairingTokenStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedToken: String?
    private var _clearCount = 0
    var loadError: Error?
    var saveError: Error?
    var clearError: Error?

    init(token: String? = nil) {
        storedToken = token
    }

    var clearCount: Int {
        lock.synchronized { _clearCount }
    }

    func load() throws -> String? {
        if let loadError { throw loadError }
        return lock.synchronized { storedToken }
    }

    func save(_ token: String) throws {
        if let saveError { throw saveError }
        lock.synchronized {
            storedToken = token
        }
    }

    func clear() throws {
        if let clearError { throw clearError }
        lock.synchronized {
            storedToken = nil
            _clearCount += 1
        }
    }
}

private final class BlockingTeamsPairingTokenStore:
    TeamsPairingTokenStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let saveStarted = DispatchSemaphore(value: 0)
    private let clearStarted = DispatchSemaphore(value: 0)
    private let allowSave = DispatchSemaphore(value: 0)
    private let allowClear = DispatchSemaphore(value: 0)
    private var token: String?

    init(token: String?) {
        self.token = token
    }

    func load() throws -> String? {
        lock.synchronized { token }
    }

    func save(_ token: String) throws {
        saveStarted.signal()
        allowSave.wait()
        lock.synchronized {
            self.token = token
        }
    }

    func clear() throws {
        clearStarted.signal()
        allowClear.wait()
        lock.synchronized {
            token = nil
        }
    }

    func waitUntilSaveStarts() async {
        await wait(for: saveStarted)
    }

    func waitUntilClearStarts() async {
        await wait(for: clearStarted)
    }

    func allowSaveToFinish() {
        allowSave.signal()
    }

    func allowClearToFinish() {
        allowClear.signal()
    }

    private func wait(for semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }
}

private final class TeamsEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [TeamsMuteSyncEvent] = []

    var events: [TeamsMuteSyncEvent] {
        lock.synchronized { recordedEvents }
    }

    func record(_ event: TeamsMuteSyncEvent) {
        lock.synchronized {
            recordedEvents.append(event)
        }
    }
}

private final class ThreadSafeTeamsFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.synchronized { storedValue }
    }

    func set() {
        lock.synchronized {
            storedValue = true
        }
    }
}

private final class TeamsPingCallbackStore: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Error?) -> Void)?

    func store(_ callback: @escaping @Sendable (Error?) -> Void) {
        lock.synchronized {
            self.callback = callback
        }
    }

    func finish(error: Error?) {
        let callback = lock.synchronized {
            let callback = self.callback
            self.callback = nil
            return callback
        }
        callback?(error)
    }
}

private enum ScriptedTeamsError: Error {
    case pingFailed
    case sendFailed
    case cancelled
    case storageFailed
}

private extension URL {
    var queryItems: [String] {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .map(\.name) ?? []
    }
}

private extension NSLock {
    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
