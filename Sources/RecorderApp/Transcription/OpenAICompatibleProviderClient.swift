import Foundation

protocol ProviderHTTPTransport: Sendable {
    func response(
        for request: URLRequest,
        maximumBodyBytes: Int
    ) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionProviderHTTPTransport: ProviderHTTPTransport {
    private let configuration: URLSessionConfiguration
    private let lifecycle: URLSessionProviderHTTPTransportLifecycle
    private let retainedBodyByteCountObserver: (@Sendable (Int) -> Void)?

    init(
        configuration: URLSessionConfiguration? = nil,
        retainedBodyByteCountObserver: (@Sendable (Int) -> Void)? = nil
    ) {
        let configured = (configuration ?? .ephemeral).copy() as! URLSessionConfiguration
        configured.urlCache = nil
        configured.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration = configured
        self.lifecycle = URLSessionProviderHTTPTransportLifecycle()
        self.retainedBodyByteCountObserver = retainedBodyByteCountObserver
    }

    var configurationForTesting: URLSessionConfiguration { configuration }
    var hasReleasedTaskAndSessionForTesting: Bool { lifecycle.hasReleased }

    func response(
        for request: URLRequest,
        maximumBodyBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let collector = CappedHTTPResponseCollector(
            configuration: configuration,
            maximumBodyBytes: maximumBodyBytes,
            lifecycle: lifecycle,
            retainedBodyByteCountObserver: retainedBodyByteCountObserver
        )
        return try await collector.load(request: request)
    }
}

private final class URLSessionProviderHTTPTransportLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0

    var hasReleased: Bool { lock.withLock { activeCount == 0 } }

    func markActive() {
        lock.withLock { activeCount += 1 }
    }

    func markReleased() {
        lock.withLock { activeCount = max(0, activeCount - 1) }
    }
}

private final class CappedHTTPResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumBodyBytes: Int
    private let lifecycle: URLSessionProviderHTTPTransportLifecycle
    private let retainedBodyByteCountObserver: (@Sendable (Int) -> Void)?
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var isFinished = false
    private var currentRedirectRequest: URLRequest?

    init(
        configuration: URLSessionConfiguration,
        maximumBodyBytes: Int,
        lifecycle: URLSessionProviderHTTPTransportLifecycle,
        retainedBodyByteCountObserver: (@Sendable (Int) -> Void)?
    ) {
        self.configuration = configuration
        self.maximumBodyBytes = maximumBodyBytes
        self.lifecycle = lifecycle
        self.retainedBodyByteCountObserver = retainedBodyByteCountObserver
    }

    func load(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                currentRedirectRequest = request
                if Task.isCancelled {
                    lock.unlock()
                    finish(.failure(CancellationError()))
                    return
                }
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lifecycle.markActive()
                lock.unlock()
                task.resume()
            }
        }, onCancel: {
            self.cancel()
        })
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(ProviderConnectionError.invalidResponse))
            return
        }
        guard response.expectedContentLength <= maximumBodyBytes
                || response.expectedContentLength == NSURLSessionTransferSizeUnknown else {
            completionHandler(.cancel)
            dataTask.cancel()
            finish(.failure(ProviderHTTPTransportError.responseTooLarge))
            return
        }
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            completionHandler(.cancel)
            dataTask.cancel()
            return
        }
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        let exceedsLimit = data.count > maximumBodyBytes - body.count
        if !exceedsLimit {
            body.append(data)
        }
        let retainedByteCount = body.count
        lock.unlock()

        if exceedsLimit {
            dataTask.cancel()
            finish(.failure(ProviderHTTPTransportError.responseTooLarge))
        } else {
            retainedBodyByteCountObserver?(retainedByteCount)
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let result = response.map { (body, $0) }
        lock.unlock()
        guard let result else {
            finish(.failure(ProviderConnectionError.invalidResponse))
            return
        }
        finish(.success(result))
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let redirected = currentRedirectRequest.flatMap {
            ProviderRedirectPolicy.redirectedRequest(
                from: $0,
                proposed: request,
                statusCode: response.statusCode
            )
        }
        if let redirected {
            currentRedirectRequest = redirected
        }
        lock.unlock()

        guard let redirected else {
            completionHandler(nil)
            task.cancel()
            finish(
                .failure(ProviderHTTPTransportError.redirectRejected)
            )
            return
        }
        completionHandler(redirected)
    }

    private func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        isFinished = true
        self.continuation = nil
        task = nil
        let session = self.session
        self.session = nil
        body.removeAll(keepingCapacity: false)
        response = nil
        currentRedirectRequest = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        lifecycle.markReleased()
        continuation.resume(with: result)
    }
}

struct ProviderConnectionReport: Equatable, Sendable {
    let supportsModelDiscovery: Bool
    let models: [String]
}

protocol ProviderConnectionTesting: Sendable {
    func testConnection(
        profile: OpenAICompatibleProviderProfile,
        apiKey: String?
    ) async throws -> ProviderConnectionReport
}

enum ProviderConnectionError: LocalizedError, Equatable {
    case invalidResponse
    case authenticationRejected
    case tooManyDiscoveredModels
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The provider returned an invalid response."
        case .authenticationRejected:
            "The provider rejected the API key."
        case .tooManyDiscoveredModels:
            "The provider returned too many models."
        case .httpStatus(let status):
            "The provider returned HTTP \(status)."
        }
    }
}

struct OpenAICompatibleProviderClient: ProviderConnectionTesting {
    static let maximumModelDiscoveryResponseBytes = 1_048_576
    static let maximumDiscoveredModelCount = 1_000

    private let transport: any ProviderHTTPTransport

    init(
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
    ) {
        self.transport = transport
    }

    func testConnection(
        profile: OpenAICompatibleProviderProfile,
        apiKey: String?
    ) async throws -> ProviderConnectionReport {
        var request = URLRequest(
            url: profile.baseURL.appendingPathComponent("models")
        )
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await transport.response(
            for: request,
            maximumBodyBytes: Self.maximumModelDiscoveryResponseBytes
        )
        switch response.statusCode {
        case 200..<300:
            let decoded = try? JSONDecoder().decode(ModelList.self, from: data)
            if let decoded,
               decoded.data.count > Self.maximumDiscoveredModelCount {
                throw ProviderConnectionError.tooManyDiscoveredModels
            }
            return ProviderConnectionReport(
                supportsModelDiscovery: decoded != nil,
                models: decoded.map { Array(Set($0.data.map(\.id))).sorted() } ?? []
            )
        case 404, 405:
            return ProviderConnectionReport(
                supportsModelDiscovery: false,
                models: []
            )
        case 401, 403:
            throw ProviderConnectionError.authenticationRejected
        default:
            throw ProviderConnectionError.httpStatus(response.statusCode)
        }
    }

    private struct ModelList: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }
}
