import RecorderControl

@MainActor
final class RecorderControlServerRuntime {
    private let adapter: AppModelControlAdapter
    private let server: RecorderControlSocketServer

    init(model: AppModel, bundleIdentifier: String) {
        let adapter = AppModelControlAdapter(model: model)
        self.adapter = adapter
        server = RecorderControlSocketServer(
            bundleIdentifier: bundleIdentifier,
            handler: { request in
                await adapter.handle(request)
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
        self.adapter = adapter
        server = serverFactory { request in
            await adapter.handle(request)
        }
    }

    func start() throws {
        try server.start()
    }

    func stop() {
        server.stop()
    }
}
