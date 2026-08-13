import RecorderControl

@MainActor
final class RecorderControlServerRuntime {
    private let adapter: AppModelControlAdapter
    private let requestGate: RecorderControlRequestGate
    private let server: RecorderControlSocketServer
    private var isRunning = false

    init(model: AppModel, bundleIdentifier: String) {
        let adapter = AppModelControlAdapter(model: model)
        let requestGate = RecorderControlRequestGate(adapter: adapter)
        self.adapter = adapter
        self.requestGate = requestGate
        server = RecorderControlSocketServer(
            bundleIdentifier: bundleIdentifier,
            handler: { request in
                await requestGate.handle(request)
            }
        )
    }

    init(
        model: AppModel,
        serverFactory: (
            _ handler: @escaping RecorderControlSocketServer.Handler
        ) -> RecorderControlSocketServer
    ) {
        let adapter = AppModelControlAdapter(model: model)
        let requestGate = RecorderControlRequestGate(adapter: adapter)
        self.adapter = adapter
        self.requestGate = requestGate
        server = serverFactory { request in
            await requestGate.handle(request)
        }
    }

    func start() throws {
        guard !isRunning else { return }
        requestGate.activate()
        do {
            try server.start()
            isRunning = true
        } catch {
            requestGate.deactivate()
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        requestGate.deactivate()
        server.stop()
        isRunning = false
    }
}

@MainActor
private final class RecorderControlRequestGate {
    private let adapter: AppModelControlAdapter
    private var isActive = false

    init(adapter: AppModelControlAdapter) {
        self.adapter = adapter
    }

    func activate() {
        isActive = true
    }

    func deactivate() {
        isActive = false
    }

    func handle(_ request: RecorderControlRequest) async -> RecorderControlResponse {
        guard isActive else {
            return RecorderControlResponse(
                protocolVersion: RecorderControlRequest.currentProtocolVersion,
                requestID: request.requestID,
                ok: false,
                status: nil,
                error: .init(
                    code: "server_stopped",
                    message: "Recorder control server is stopped."
                )
            )
        }
        return await adapter.handle(request)
    }
}
