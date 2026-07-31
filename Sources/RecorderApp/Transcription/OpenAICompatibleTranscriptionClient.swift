import Foundation

enum TranscriptionResponseFormat: String, Equatable, Sendable {
    case verboseJSON = "verbose_json"
    case json
}

struct ProviderTranscriptionResult: Equatable, Sendable {
    let text: String
    let responseFormat: TranscriptionResponseFormat
}

enum OpenAICompatibleTranscriptionError:
    LocalizedError,
    Equatable,
    Sendable
{
    case audioChunkTooLarge
    case invalidResponse
    case authenticationRejected
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .audioChunkTooLarge:
            "The prepared transcription chunk is too large."
        case .invalidResponse:
            "The provider returned an invalid transcription response."
        case .authenticationRejected:
            "The provider rejected the API key."
        case .httpStatus(let status):
            "The provider returned HTTP \(status) during transcription."
        }
    }
}

struct TranscriptionRetryPolicy: Equatable, Sendable {
    static let maximumDelay: TimeInterval = 60

    let maximumAttempts: Int

    init(maximumAttempts: Int = 3) {
        self.maximumAttempts = max(1, maximumAttempts)
    }

    func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 408
            || statusCode == 429
            || (500...599).contains(statusCode)
    }

    func shouldRetry(error: Error) -> Bool {
        guard !(error is CancellationError),
              let urlError = error as? URLError else {
            return false
        }
        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    func delay(
        after response: HTTPURLResponse,
        failedAttempt: Int,
        now: Date = Date(),
        jitter: @Sendable (Double) -> Double
    ) -> Double {
        if let value = response.value(
            forHTTPHeaderField: "Retry-After"
        )?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let seconds = Double(value), seconds >= 0 {
                return min(Self.maximumDelay, seconds)
            }
            if let retryDate = Self.httpDate(value) {
                return min(
                    Self.maximumDelay,
                    max(0, retryDate.timeIntervalSince(now))
                )
            }
        }
        return fallbackDelay(
            failedAttempt: failedAttempt,
            jitter: jitter
        )
    }

    func delay(
        failedAttempt: Int,
        jitter: @Sendable (Double) -> Double
    ) -> Double {
        fallbackDelay(
            failedAttempt: failedAttempt,
            jitter: jitter
        )
    }

    private func fallbackDelay(
        failedAttempt: Int,
        jitter: @Sendable (Double) -> Double
    ) -> Double {
        let base = min(8, pow(2, Double(max(0, failedAttempt))))
        return min(
            Self.maximumDelay,
            base + max(0, jitter(base))
        )
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}

struct TranscriptionMultipartBuilder: Sendable {
    let maximumAudioBytes: Int
    let boundary: String

    func makeBody(
        audioData: Data,
        fileName: String,
        model: String,
        language: String,
        prompt: String,
        responseFormat: TranscriptionResponseFormat
    ) throws -> Data {
        guard audioData.count <= maximumAudioBytes else {
            throw OpenAICompatibleTranscriptionError.audioChunkTooLarge
        }

        var body = Data()
        appendField(name: "model", value: model, to: &body)
        appendField(name: "language", value: language, to: &body)
        appendField(name: "prompt", value: prompt, to: &body)
        appendField(
            name: "response_format",
            value: responseFormat.rawValue,
            to: &body
        )
        append("--\(boundary)\r\n", to: &body)
        let safeName = fileName
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        append(
            "Content-Disposition: form-data; name=\"file\"; "
                + "filename=\"\(safeName)\"\r\n",
            to: &body
        )
        append(
            "Content-Type: \(mimeType(for: fileName))\r\n\r\n",
            to: &body
        )
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n", to: &body)
        return body
    }

    private func appendField(
        name: String,
        value: String,
        to body: inout Data
    ) {
        append("--\(boundary)\r\n", to: &body)
        append(
            "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n",
            to: &body
        )
        append(value, to: &body)
        append("\r\n", to: &body)
    }

    private func append(_ value: String, to body: inout Data) {
        body.append(contentsOf: value.utf8)
    }

    private func mimeType(for fileName: String) -> String {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "m4a", "mp4":
            "audio/mp4"
        case "mp3":
            "audio/mpeg"
        case "wav":
            "audio/wav"
        case "flac":
            "audio/flac"
        default:
            "application/octet-stream"
        }
    }
}

struct OpenAICompatibleTranscriptionClient: Sendable {
    static let maximumAudioBytes = 32 * 1_024 * 1_024
    static let maximumResponseBytes = 2 * 1_024 * 1_024

    typealias Sleep = @Sendable (Double) async throws -> Void
    typealias Jitter = @Sendable (Double) -> Double
    typealias Boundary = @Sendable () -> String

    private let transport: any ProviderHTTPTransport
    private let retryPolicy: TranscriptionRetryPolicy
    private let sleep: Sleep
    private let jitter: Jitter
    private let boundary: Boundary

    init(
        transport: any ProviderHTTPTransport =
            URLSessionProviderHTTPTransport(),
        retryPolicy: TranscriptionRetryPolicy = .init(),
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        jitter: @escaping Jitter = { base in
            Double.random(in: 0...(base * 0.2))
        },
        boundary: @escaping Boundary = {
            "LocalMeetingRecorder-\(UUID().uuidString)"
        }
    ) {
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.sleep = sleep
        self.jitter = jitter
        self.boundary = boundary
    }

    func transcribe(
        audioData: Data,
        fileName: String,
        snapshot: OpenAICompatibleProviderSnapshot,
        prompt: String
    ) async throws -> ProviderTranscriptionResult {
        do {
            return try await send(
                audioData: audioData,
                fileName: fileName,
                snapshot: snapshot,
                prompt: prompt,
                responseFormat: .verboseJSON
            )
        } catch OpenAICompatibleTranscriptionError.httpStatus(
            let status
        ) where status == 400 || status == 422 {
            return try await send(
                audioData: audioData,
                fileName: fileName,
                snapshot: snapshot,
                prompt: prompt,
                responseFormat: .json
            )
        }
    }

    private func send(
        audioData: Data,
        fileName: String,
        snapshot: OpenAICompatibleProviderSnapshot,
        prompt: String,
        responseFormat: TranscriptionResponseFormat
    ) async throws -> ProviderTranscriptionResult {
        let multipartBoundary = boundary()
        let body = try TranscriptionMultipartBuilder(
            maximumAudioBytes: Self.maximumAudioBytes,
            boundary: multipartBoundary
        ).makeBody(
            audioData: audioData,
            fileName: fileName,
            model: snapshot.profile.asrModel,
            language: snapshot.profile.language,
            prompt: prompt,
            responseFormat: responseFormat
        )
        var request = URLRequest(
            url: snapshot.profile.baseURL.appendingPathComponent(
                "audio/transcriptions"
            )
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 7_200
        request.httpBody = body
        request.setValue(
            "multipart/form-data; boundary=\(multipartBoundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        if let apiKey = snapshot.apiKey, !apiKey.isEmpty {
            request.setValue(
                "Bearer \(apiKey)",
                forHTTPHeaderField: "Authorization"
            )
        }

        for attempt in 0..<retryPolicy.maximumAttempts {
            try Task.checkCancellation()
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.response(
                    for: request,
                    maximumBodyBytes: Self.maximumResponseBytes
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard retryPolicy.shouldRetry(error: error),
                      attempt + 1 < retryPolicy.maximumAttempts else {
                    throw error
                }
                try await sleep(
                    retryPolicy.delay(
                        failedAttempt: attempt,
                        jitter: jitter
                    )
                )
                continue
            }
            try Task.checkCancellation()
            switch response.statusCode {
            case 200..<300:
                let payload = try? JSONDecoder().decode(
                    TranscriptionPayload.self,
                    from: data
                )
                guard let text = payload?.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ), !text.isEmpty else {
                    throw OpenAICompatibleTranscriptionError.invalidResponse
                }
                return .init(
                    text: text,
                    responseFormat: responseFormat
                )
            case 401, 403:
                throw OpenAICompatibleTranscriptionError
                    .authenticationRejected
            default:
                guard retryPolicy.shouldRetry(
                    statusCode: response.statusCode
                ), attempt + 1 < retryPolicy.maximumAttempts else {
                    throw OpenAICompatibleTranscriptionError.httpStatus(
                        response.statusCode
                    )
                }
                try await sleep(
                    retryPolicy.delay(
                        after: response,
                        failedAttempt: attempt,
                        jitter: jitter
                    )
                )
            }
        }
        throw OpenAICompatibleTranscriptionError.invalidResponse
    }

    private struct TranscriptionPayload: Decodable {
        let text: String
    }
}

enum ProviderHTTPTransportError: LocalizedError, Equatable, Sendable {
    case redirectRejected
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .redirectRejected:
            "The provider attempted an unsafe HTTP redirect."
        case .responseTooLarge:
            "The provider response was too large."
        }
    }
}
