import Foundation

enum TeamsMuteSyncStatus: Equatable, Sendable {
    case disabled
    case connecting
    case waitingForTeamsAPI
    case waitingForMeeting
    case waitingForPairingApproval
    case ready
    case inMeeting(muted: Bool)
    case failed(String)
}

extension TeamsMuteSyncStatus {
    static var pairingResetRequired: TeamsMuteSyncStatus {
        .failed(
            """
            Teams reports that this recorder is already paired. Open Teams \
            Settings > Privacy > Manage API, forget Local Meeting Recorder, \
            then retry pairing.
            """
        )
    }
}

enum TeamsMuteSyncEvent: Equatable, Sendable {
    case status(TeamsMuteSyncStatus)
    case meetingState(TeamsMeetingState)
}

protocol TeamsMuteSyncing: AnyObject {
    func start(onEvent: @escaping (TeamsMuteSyncEvent) -> Void)
    func stop()
    func reconnect()
    func requestPairing()
}

protocol TeamsPairingTokenStoring: AnyObject {
    func load() throws -> String?
    func save(_ token: String) throws
    func clear() throws
}

protocol TeamsWebSocketConnection: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func ping() async throws
    func cancel(
        with closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    )
}

typealias TeamsWebSocketConnectionFactory =
    @Sendable (URL) -> any TeamsWebSocketConnection

typealias TeamsMuteSyncSleep =
    @Sendable (Duration) async throws -> Void

final class TeamsWebSocketPingWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func wait(
        start: (@escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completedResult: Result<Void, Error>? = lock.withLock {
                    if let result {
                        return result
                    }
                    self.continuation = continuation
                    return nil
                }

                if let completedResult {
                    continuation.resume(with: completedResult)
                    return
                }

                start { [weak self] error in
                    self?.finish(
                        error.map(Result.failure) ?? .success(())
                    )
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

final class URLSessionTeamsWebSocketConnection:
    TeamsWebSocketConnection,
    @unchecked Sendable
{
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() {
        task.resume()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func ping() async throws {
        let waiter = TeamsWebSocketPingWaiter()
        try await withTaskCancellationHandler {
            try await waiter.wait { [task] completion in
                task.sendPing(pongReceiveHandler: completion)
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    func cancel(
        with closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        task.cancel(with: closeCode, reason: reason)
    }
}

final class TeamsMuteSyncClient: TeamsMuteSyncing, @unchecked Sendable {
    private enum PairingPhase {
        case idle
        case awaitingResponse(requestID: Int)
        case retryRequired
    }

    private enum ClientError: Error {
        case staleConnection
        case invalidCommand
        case heartbeatTimedOut
    }

    private struct ConnectionContext {
        let socket: any TeamsWebSocketConnection
        let generation: UInt64
    }

    private let identity: TeamsThirdPartyAPIIdentity
    private let tokenStore: TeamsPairingTokenStoring
    private let reconnectDelay: Duration
    private let heartbeatInterval: Duration
    private let pingTimeout: Duration
    private let connectionFactory: TeamsWebSocketConnectionFactory
    private let sleep: TeamsMuteSyncSleep
    private let lock = NSLock()
    private let eventDeliveryLock = NSRecursiveLock()

    private var onEvent: ((TeamsMuteSyncEvent) -> Void)?
    private var runTask: Task<Void, Never>?
    private var socketTask: (any TeamsWebSocketConnection)?
    private var generation: UInt64 = 0
    private var requestID = 0
    private var pairingPhase = PairingPhase.idle

    init(
        identity: TeamsThirdPartyAPIIdentity = .recorder(
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "1.0"
        ),
        tokenStore: TeamsPairingTokenStoring = KeychainTeamsPairingTokenStore(),
        urlSession: URLSession = .shared,
        reconnectDelay: Duration = .seconds(2),
        heartbeatInterval: Duration = .seconds(2),
        pingTimeout: Duration = .seconds(2),
        connectionFactory: TeamsWebSocketConnectionFactory? = nil,
        sleep: @escaping TeamsMuteSyncSleep = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.identity = identity
        self.tokenStore = tokenStore
        self.reconnectDelay = reconnectDelay
        self.heartbeatInterval = heartbeatInterval
        self.pingTimeout = pingTimeout
        self.sleep = sleep
        if let connectionFactory {
            self.connectionFactory = connectionFactory
        } else {
            self.connectionFactory = { endpoint in
                URLSessionTeamsWebSocketConnection(
                    task: urlSession.webSocketTask(with: endpoint)
                )
            }
        }
    }

    func start(onEvent: @escaping (TeamsMuteSyncEvent) -> Void) {
        let launch: (generation: UInt64, task: Task<Void, Never>)? =
            eventDeliveryLock.withLock {
                lock.withLock {
                    self.onEvent = onEvent
                    guard runTask == nil else { return nil }
                    generation &+= 1
                    let currentGeneration = generation
                    pairingPhase = .idle
                    let task = Task { [weak self] in
                        guard let self else { return }
                        await self.run(generation: currentGeneration)
                    }
                    runTask = task
                    return (currentGeneration, task)
                }
            }
        guard launch != nil else { return }
    }

    func stop() {
        let stopped: (
            callback: ((TeamsMuteSyncEvent) -> Void)?,
            runTask: Task<Void, Never>?,
            socketTask: (any TeamsWebSocketConnection)?
        ) = eventDeliveryLock.withLock {
            let stopped: (
                callback: ((TeamsMuteSyncEvent) -> Void)?,
                runTask: Task<Void, Never>?,
                socketTask: (any TeamsWebSocketConnection)?
            ) = lock.withLock {
                generation &+= 1
                let stopped = (
                    callback: onEvent,
                    runTask: runTask,
                    socketTask: socketTask
                )
                onEvent = nil
                runTask = nil
                socketTask = nil
                pairingPhase = .idle
                return stopped
            }
            stopped.callback?(.status(.disabled))
            return stopped
        }
        stopped.runTask?.cancel()
        stopped.socketTask?.cancel(with: .goingAway, reason: nil)
    }

    func reconnect() {
        restart(ifCurrent: nil)
    }

    func requestPairing() {
        let request: (context: ConnectionContext, requestID: Int)? =
            lock.withLock {
                guard let socketTask,
                      let requestID = beginPairingRequestLocked(
                        explicit: true
                      ) else {
                    return nil
                }
                return (
                    ConnectionContext(
                        socket: socketTask,
                        generation: generation
                    ),
                    requestID
                )
            }
        guard let request else { return }
        emit(
            .status(.waitingForPairingApproval),
            generation: request.context.generation
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                try await send(
                    action: .pair,
                    requestID: request.requestID,
                    through: request.context.socket,
                    generation: request.context.generation
                )
            } catch {
                restart(ifCurrent: request.context)
            }
        }
    }

    private func restart(ifCurrent expected: ConnectionContext?) {
        let restart: (
            callback: ((TeamsMuteSyncEvent) -> Void)?,
            oldRunTask: Task<Void, Never>?,
            oldSocketTask: (any TeamsWebSocketConnection)?,
            generation: UInt64
        )? = eventDeliveryLock.withLock {
            lock.withLock {
                if let expected {
                    guard generation == expected.generation,
                          let socketTask,
                          connectionsMatch(socketTask, expected.socket) else {
                        return nil
                    }
                }
                generation &+= 1
                let nextGeneration = generation
                let restart = (onEvent, runTask, socketTask, nextGeneration)
                runTask = nil
                socketTask = nil
                pairingPhase = .idle
                return restart
            }
        }
        guard let restart else { return }

        restart.oldRunTask?.cancel()
        restart.oldSocketTask?.cancel(with: .goingAway, reason: nil)
        guard restart.callback != nil else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(generation: restart.generation)
        }
        lock.withLock {
            guard generation == restart.generation else {
                task.cancel()
                return
            }
            runTask = task
        }
    }

    private func run(generation: UInt64) async {
        while !Task.isCancelled, isCurrent(generation) {
            emit(.status(.connecting), generation: generation)

            let token: String?
            do {
                token = try tokenStore.load()
            } catch {
                emitCredentialFailure(generation: generation)
                return
            }
            var activeToken = token
            guard let endpoint = TeamsThirdPartyAPI.endpoint(
                token: token,
                identity: identity
            ) else {
                emit(
                    .status(.failed("Cannot create Teams API endpoint")),
                    generation: generation
                )
                return
            }

            let socket = connectionFactory(endpoint)
            guard install(socket: socket, generation: generation) else {
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
            socket.resume()

            var shouldReconnectImmediately = false
            do {
                try await send(
                    action: .queryState,
                    through: socket,
                    generation: generation
                )
                emit(
                    .status(activeToken == nil ? .waitingForMeeting : .ready),
                    generation: generation
                )
                let heartbeatTask = Task { [weak self] in
                    guard let self else { return }
                    await monitorHeartbeat(
                        socket: socket,
                        generation: generation
                    )
                }
                defer {
                    heartbeatTask.cancel()
                }

                while !Task.isCancelled, isCurrent(generation) {
                    let message = try await socket.receive()
                    guard isInstalled(
                        socket: socket,
                        generation: generation
                    ) else {
                        return
                    }
                    let text: String
                    switch message {
                    case .string(let value):
                        text = value
                    case .data(let data):
                        guard let value = String(data: data, encoding: .utf8) else {
                            continue
                        }
                        text = value
                    @unknown default:
                        continue
                    }

                    switch try TeamsThirdPartyAPI.decode(text) {
                    case .meetingUpdate(let update):
                        let hasToken = activeToken != nil
                        if update.canPair, !hasToken {
                            if let state = update.state {
                                emit(
                                    .meetingState(state),
                                    generation: generation
                                )
                            }
                            emit(
                                .status(.waitingForPairingApproval),
                                generation: generation
                            )
                            if let requestID = beginPairingRequest(
                                explicit: false,
                                socket: socket,
                                generation: generation
                            ) {
                                try await send(
                                    action: .pair,
                                    requestID: requestID,
                                    through: socket,
                                    generation: generation
                                )
                            }
                            continue
                        }

                        guard let state = update.state else {
                            emit(
                                .status(hasToken ? .ready : .waitingForMeeting),
                                generation: generation
                            )
                            continue
                        }

                        emit(.meetingState(state), generation: generation)
                        let status: TeamsMuteSyncStatus
                        if state.isInMeeting {
                            status = hasToken || update.canToggleMute
                                ? .inMeeting(muted: state.isMuted)
                                : .waitingForMeeting
                        } else {
                            status = hasToken ? .ready : .waitingForMeeting
                        }
                        emit(.status(status), generation: generation)

                    case .tokenRefresh(let token):
                        let saved = mutateCredentialIfInstalled(
                            socket: socket,
                            generation: generation,
                            operation: { try tokenStore.save(token) },
                            onSuccess: { pairingPhase = .idle }
                        )
                        switch saved {
                        case nil:
                            return
                        case .failure:
                            emitCredentialFailure(generation: generation)
                            clear(socket: socket, generation: generation)
                            socket.cancel(with: .goingAway, reason: nil)
                            return
                        case .success:
                            activeToken = token
                            emit(.status(.ready), generation: generation)
                            try await send(
                                action: .queryState,
                                through: socket,
                                generation: generation
                            )
                        }

                    case .error(let requestID, let message):
                        if message.localizedCaseInsensitiveContains("invalid token") {
                            let cleared = mutateCredentialIfInstalled(
                                socket: socket,
                                generation: generation,
                                operation: { try tokenStore.clear() }
                            )
                            switch cleared {
                            case nil:
                                return
                            case .failure:
                                emitCredentialFailure(generation: generation)
                                clear(socket: socket, generation: generation)
                                socket.cancel(with: .goingAway, reason: nil)
                                return
                            case .success:
                                activeToken = nil
                                shouldReconnectImmediately = true
                                break
                            }
                            break
                        }
                        if isDeviceAlreadyPaired(message) {
                            guard requireExplicitPairingRetry(
                                requestID: requestID,
                                socket: socket,
                                generation: generation
                            ) else {
                                break
                            }
                            emit(
                                .status(.pairingResetRequired),
                                generation: generation
                            )
                        } else if message.localizedCaseInsensitiveContains(
                            "disabled"
                        ) {
                            emit(.status(.waitingForTeamsAPI), generation: generation)
                        } else {
                            emit(
                                .status(.failed("Teams API reported an error.")),
                                generation: generation
                            )
                        }

                    case .response(let requestID, let message):
                        if isDeviceAlreadyPaired(message) {
                            guard requireExplicitPairingRetry(
                                requestID: requestID,
                                socket: socket,
                                generation: generation
                            ) else {
                                break
                            }
                            emit(
                                .status(.pairingResetRequired),
                                generation: generation
                            )
                        } else if message.localizedCaseInsensitiveContains(
                            "no action"
                        ) {
                            guard requireExplicitPairingRetry(
                                requestID: requestID,
                                socket: socket,
                                generation: generation
                            ) else {
                                break
                            }
                            emit(
                                .status(.waitingForPairingApproval),
                                generation: generation
                            )
                        }

                    case .ignored:
                        break
                    }

                    if shouldReconnectImmediately {
                        break
                    }
                }
            } catch {
                if !Task.isCancelled, isCurrent(generation) {
                    emit(.status(.waitingForTeamsAPI), generation: generation)
                }
            }

            clear(socket: socket, generation: generation)
            socket.cancel(with: .goingAway, reason: nil)
            guard !Task.isCancelled, isCurrent(generation) else { return }
            if !shouldReconnectImmediately {
                do {
                    try await sleep(reconnectDelay)
                } catch {
                    return
                }
            }
        }
    }

    private func monitorHeartbeat(
        socket: any TeamsWebSocketConnection,
        generation: UInt64
    ) async {
        while !Task.isCancelled,
              isInstalled(socket: socket, generation: generation) {
            do {
                try await sleep(heartbeatInterval)
                guard !Task.isCancelled,
                      isInstalled(
                        socket: socket,
                        generation: generation
                      ) else {
                    return
                }
                try await pingWithTimeout(
                    socket: socket,
                    generation: generation
                )
            } catch {
                guard !Task.isCancelled,
                      isInstalled(
                        socket: socket,
                        generation: generation
                      ) else {
                    return
                }
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    private func pingWithTimeout(
        socket: any TeamsWebSocketConnection,
        generation: UInt64
    ) async throws {
        let sleep = self.sleep
        let pingTimeout = self.pingTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await socket.ping()
            }
            group.addTask { [weak self] in
                try await sleep(pingTimeout)
                guard let self,
                      isInstalled(
                        socket: socket,
                        generation: generation
                      ) else {
                    throw CancellationError()
                }
                socket.cancel(with: .goingAway, reason: nil)
                throw ClientError.heartbeatTimedOut
            }
            defer {
                group.cancelAll()
            }
            _ = try await group.next()
        }
    }

    private func send(
        action: TeamsThirdPartyAPIAction,
        through socket: any TeamsWebSocketConnection,
        generation: UInt64
    ) async throws {
        guard let id = nextRequestID(
            socket: socket,
            generation: generation
        ) else {
            throw ClientError.staleConnection
        }
        try await send(
            action: action,
            requestID: id,
            through: socket,
            generation: generation
        )
    }

    private func send(
        action: TeamsThirdPartyAPIAction,
        requestID: Int,
        through socket: any TeamsWebSocketConnection,
        generation: UInt64
    ) async throws {
        guard isInstalled(socket: socket, generation: generation) else {
            throw ClientError.staleConnection
        }
        let data = TeamsThirdPartyAPI.command(
            action: action,
            requestID: requestID
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClientError.invalidCommand
        }
        try await socket.send(.string(text))
    }

    private func emit(_ event: TeamsMuteSyncEvent, generation: UInt64) {
        eventDeliveryLock.withLock {
            let callback: ((TeamsMuteSyncEvent) -> Void)? = lock.withLock {
                guard self.generation == generation else { return nil }
                return onEvent
            }
            callback?(event)
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock {
            self.generation == generation && onEvent != nil
        }
    }

    private func install(
        socket: any TeamsWebSocketConnection,
        generation: UInt64
    ) -> Bool {
        lock.withLock {
            guard self.generation == generation, onEvent != nil else {
                return false
            }
            socketTask = socket
            pairingPhase = .idle
            return true
        }
    }

    private func clear(
        socket: any TeamsWebSocketConnection,
        generation: UInt64
    ) {
        lock.withLock {
            guard self.generation == generation,
                  let socketTask,
                  connectionsMatch(socketTask, socket) else {
                return
            }
            self.socketTask = nil
            pairingPhase = .idle
        }
    }

    private func isInstalled(
        socket: any TeamsWebSocketConnection,
        generation: UInt64
    ) -> Bool {
        lock.withLock {
            guard self.generation == generation,
                  onEvent != nil,
                  let socketTask else {
                return false
            }
            return connectionsMatch(socketTask, socket)
        }
    }

    private func beginPairingRequest(
        explicit: Bool,
        socket: any TeamsWebSocketConnection,
        generation: UInt64
    ) -> Int? {
        lock.withLock {
            guard self.generation == generation,
                  let socketTask,
                  connectionsMatch(socketTask, socket) else {
                return nil
            }
            return beginPairingRequestLocked(explicit: explicit)
        }
    }

    private func beginPairingRequestLocked(explicit: Bool) -> Int? {
        switch pairingPhase {
        case .idle:
            break
        case .awaitingResponse:
            return nil
        case .retryRequired:
            guard explicit else { return nil }
        }

        requestID &+= 1
        pairingPhase = .awaitingResponse(requestID: requestID)
        return requestID
    }

    @discardableResult
    private func requireExplicitPairingRetry(
        requestID: Int?,
        socket: any TeamsWebSocketConnection,
        generation: UInt64
    ) -> Bool {
        lock.withLock {
            guard self.generation == generation,
                  let socketTask,
                  connectionsMatch(socketTask, socket) else {
                return false
            }
            guard case .awaitingResponse(let expectedRequestID) = pairingPhase,
                  requestID == nil || requestID == expectedRequestID else {
                return false
            }
            pairingPhase = .retryRequired
            return true
        }
    }

    private func emitCredentialFailure(generation: UInt64) {
        emit(
            .status(.failed(
                "Teams pairing credential is unavailable in Keychain. "
                    + "Retry after allowing Keychain access."
            )),
            generation: generation
        )
    }

    private func mutateCredentialIfInstalled(
        socket: any TeamsWebSocketConnection,
        generation: UInt64,
        operation: () throws -> Void,
        onSuccess: () -> Void = {}
    ) -> Result<Void, Error>? {
        lock.withLock {
            guard self.generation == generation,
                  onEvent != nil,
                  let socketTask,
                  connectionsMatch(socketTask, socket) else {
                return nil
            }
            do {
                try operation()
                onSuccess()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
    }

    private func nextRequestID(
        socket: any TeamsWebSocketConnection,
        generation: UInt64
    ) -> Int? {
        lock.withLock {
            guard self.generation == generation,
                  onEvent != nil,
                  let socketTask,
                  connectionsMatch(socketTask, socket) else {
                return nil
            }
            requestID &+= 1
            return requestID
        }
    }

    private func connectionsMatch(
        _ lhs: any TeamsWebSocketConnection,
        _ rhs: any TeamsWebSocketConnection
    ) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }

    private func isDeviceAlreadyPaired(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("device already paired")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
