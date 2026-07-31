import Foundation
import XCTest
@testable import RecorderApp

final class MeetingIntelligenceAvailabilityTests: XCTestCase {
    func testExactLLMMatchConfirmsDifferentASRAndLLMModels() async throws {
        let snapshot = try providerSnapshot(asrModel: "asr-model", llmModel: "llm-model")
        let client = StubProviderConnectionClient(result: .success(
            .init(supportsModelDiscovery: true, models: ["asr-model", "llm-model"])
        ))

        let result = await OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
            client: client
        ).availability(for: snapshot)

        XCTAssertEqual(result, .confirmed)
        let requestedModels = await client.requestedProfiles.map(\.llmModel)
        let requestedAPIKeys = await client.requestedAPIKeys
        XCTAssertEqual(requestedModels, ["llm-model"])
        XCTAssertEqual(requestedAPIKeys, ["test-key"])
    }

    func testExactLLMMatchForHKTUsesCapturedHKTSnapshot() async throws {
        let snapshot = OpenAICompatibleProviderSnapshot(
            profile: try .hktValidated(
                groupID: "456", asrModel: "hkt-asr", llmModel: "hkt-llm",
                language: "yue", prompt: "prompt"
            ),
            apiKey: "hkt-key"
        )
        let client = StubProviderConnectionClient(result: .success(
            .init(supportsModelDiscovery: true, models: ["hkt-asr", "hkt-llm"])
        ))

        let result = await OpenAICompatibleMeetingIntelligenceAvailabilityChecker(client: client)
            .availability(for: snapshot)

        let requestedKind = await client.requestedProfiles.first?.providerKind
        let requestedKeys = await client.requestedAPIKeys
        XCTAssertEqual(result, .confirmed)
        XCTAssertEqual(requestedKind, .hktGenAI)
        XCTAssertEqual(requestedKeys, ["hkt-key"])
    }

    func testExactLLMMatchConfirmsWhenASRAndLLMModelsAreTheSame() async throws {
        let snapshot = try providerSnapshot(asrModel: "shared-model", llmModel: "shared-model")
        let client = StubProviderConnectionClient(result: .success(
            .init(supportsModelDiscovery: true, models: ["shared-model"])
        ))

        let result = await OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
            client: client
        ).availability(for: snapshot)

        XCTAssertEqual(result, .confirmed)
    }

    func testExactLLMMatchIsCaseSensitive() async throws {
        let snapshot = try providerSnapshot(llmModel: "llm-model")
        let client = StubProviderConnectionClient(result: .success(
            .init(supportsModelDiscovery: true, models: ["LLM-MODEL"])
        ))

        let result = await OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
            client: client
        ).availability(for: snapshot)

        XCTAssertEqual(result, .unconfirmed(.modelNotAdvertised))
    }

    func testEachCheckUsesFreshConnectionWithoutCaching() async throws {
        let snapshot = try providerSnapshot(llmModel: "llm-model")
        let client = StubProviderConnectionClient(result: .success(
            .init(supportsModelDiscovery: true, models: ["llm-model"])
        ))
        let checker = OpenAICompatibleMeetingIntelligenceAvailabilityChecker(client: client)

        let first = await checker.availability(for: snapshot)
        let second = await checker.availability(for: snapshot)
        let requestedModels = await client.requestedProfiles.map(\.llmModel)
        XCTAssertEqual(first, .confirmed)
        XCTAssertEqual(second, .confirmed)
        XCTAssertEqual(requestedModels, ["llm-model", "llm-model"])
    }

    func testPlaceholderModelsReturnUnconfirmedWithoutAConnection() async throws {
        let legacySnapshot = try providerSnapshot(llmModel: "legacy-unconfigured-llm")
        let client = StubProviderConnectionClient(result: .success(
            .init(supportsModelDiscovery: true, models: ["llm-model"])
        ))
        let checker = OpenAICompatibleMeetingIntelligenceAvailabilityChecker(client: client)

        let legacyResult = await checker.availability(for: legacySnapshot)
        let requestedCount = await client.requestedProfiles.count
        XCTAssertEqual(legacyResult, .unconfirmed(.placeholderModel))
        XCTAssertEqual(requestedCount, 0)
    }

    func testUnsupportedOrMalformedDiscoveryNeverConfirmsAutomaticGeneration() async throws {
        let snapshot = try providerSnapshot(llmModel: "manual-model")
        let unsupported = StubProviderConnectionClient(result: .success(
            .init(supportsModelDiscovery: false, models: [])
        ))
        let malformed = StubProviderConnectionClient(result: .success(
            .init(supportsModelDiscovery: false, models: ["manual-model"])
        ))

        let unsupportedResult = await OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
            client: unsupported
        ).availability(for: snapshot)
        let malformedResult = await OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
            client: malformed
        ).availability(for: snapshot)
        XCTAssertEqual(unsupportedResult, .unconfirmed(.discoveryUnsupported))
        XCTAssertEqual(malformedResult, .unconfirmed(.discoveryUnsupported))
    }

    func testAbsentModelReturnsTypedUnconfirmedReason() async throws {
        let snapshot = try providerSnapshot(llmModel: "llm-model")
        let client = StubProviderConnectionClient(result: .success(
            .init(supportsModelDiscovery: true, models: ["asr-model"])
        ))

        let result = await OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
            client: client
        ).availability(for: snapshot)
        XCTAssertEqual(result, .unconfirmed(.modelNotAdvertised))
    }

    func testAuthenticationRejectionReturnsTypedUnconfirmedReason() async throws {
        let snapshot = try providerSnapshot()
        let client = StubProviderConnectionClient(
            result: .failure(ProviderConnectionError.authenticationRejected)
        )

        let result = await OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
            client: client
        ).availability(for: snapshot)
        XCTAssertEqual(result, .unconfirmed(.authenticationRejected))
    }

    func testTimeoutAndOverLimitReturnConnectionFailed() async throws {
        let snapshot = try providerSnapshot()
        let timeout = StubProviderConnectionClient(result: .failure(URLError(.timedOut)))
        let overLimit = StubProviderConnectionClient(
            result: .failure(ProviderConnectionError.tooManyDiscoveredModels)
        )

        let timeoutResult = await OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
            client: timeout
        ).availability(for: snapshot)
        let overLimitResult = await OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
            client: overLimit
        ).availability(for: snapshot)
        XCTAssertEqual(timeoutResult, .unconfirmed(.connectionFailed))
        XCTAssertEqual(overLimitResult, .unconfirmed(.connectionFailed))
    }

    func testCancellationCannotPresentConfirmedAvailability() async throws {
        let snapshot = try providerSnapshot(llmModel: "llm-model")
        let client = ControlledAvailabilityClient()
        let checker = OpenAICompatibleMeetingIntelligenceAvailabilityChecker(client: client)
        let task = Task { await checker.availability(for: snapshot) }

        await client.waitForRequestStarted()
        task.cancel()
        await client.releaseResponse(
            .init(supportsModelDiscovery: true, models: ["llm-model"])
        )

        let result = await task.value
        let requestCount = await client.requestCount
        XCTAssertEqual(result, .unconfirmed(.connectionFailed))
        XCTAssertEqual(requestCount, 1)
    }

    func testPreEntryCancellationSkipsProviderConnection() async throws {
        let snapshot = try providerSnapshot(llmModel: "llm-model")
        let client = StubProviderConnectionClient(result: .success(
            .init(supportsModelDiscovery: true, models: ["llm-model"])
        ))
        let checker = OpenAICompatibleMeetingIntelligenceAvailabilityChecker(client: client)
        let enterAvailability = AsyncBarrier()
        let task = Task {
            await enterAvailability.wait()
            return await checker.availability(for: snapshot)
        }

        task.cancel()
        await enterAvailability.open()

        let result = await task.value
        let requestCount = await client.requestedProfiles.count
        XCTAssertEqual(result, .unconfirmed(.connectionFailed))
        XCTAssertEqual(requestCount, 0)
    }
}

private actor StubProviderConnectionClient: ProviderConnectionTesting {
    private let result: Result<ProviderConnectionReport, Error>
    private(set) var requestedProfiles: [OpenAICompatibleProviderProfile] = []
    private(set) var requestedAPIKeys: [String?] = []

    init(result: Result<ProviderConnectionReport, Error>) {
        self.result = result
    }

    func testConnection(
        for snapshot: OpenAICompatibleProviderSnapshot
    ) async throws -> ProviderConnectionReport {
        requestedProfiles.append(snapshot.profile)
        requestedAPIKeys.append(snapshot.apiKey)
        return try result.get()
    }
}

private actor ControlledAvailabilityClient: ProviderConnectionTesting {
    private let requestStarted = AsyncBarrier()
    private let releaseResponse = AsyncBarrier()
    private var response: ProviderConnectionReport?
    private(set) var requestCount = 0

    func testConnection(
        for snapshot: OpenAICompatibleProviderSnapshot
    ) async throws -> ProviderConnectionReport {
        requestCount += 1
        await requestStarted.open()
        await releaseResponse.wait()
        return response!
    }

    func waitForRequestStarted() async {
        await requestStarted.wait()
    }

    func releaseResponse(_ response: ProviderConnectionReport) async {
        self.response = response
        await releaseResponse.open()
    }
}

private actor AsyncBarrier {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func providerSnapshot(
    asrModel: String = "asr-model",
    llmModel: String = "llm-model"
) throws -> OpenAICompatibleProviderSnapshot {
    try OpenAICompatibleProviderSnapshot.validated(
        profile: .validated(
            baseURLText: "https://provider.example/v1",
            asrModel: asrModel,
            llmModel: llmModel,
            language: "en",
            prompt: "Summarize this meeting."
        ),
        apiKey: "test-key"
    )
}
