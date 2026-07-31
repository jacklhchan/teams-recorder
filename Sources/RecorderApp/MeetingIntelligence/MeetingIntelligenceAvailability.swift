import Foundation

enum MeetingIntelligenceAvailability: Equatable, Sendable {
    case confirmed
    case unconfirmed(MeetingIntelligenceUnavailableReason)
}

enum MeetingIntelligenceUnavailableReason: Equatable, Sendable {
    case missingProfile
    case placeholderModel
    case discoveryUnsupported
    case modelNotAdvertised
    case authenticationRejected
    case connectionFailed
    case unsafeTranscript
}

protocol MeetingIntelligenceAvailabilityChecking: Sendable {
    func availability(
        for snapshot: OpenAICompatibleProviderSnapshot
    ) async -> MeetingIntelligenceAvailability
}

struct OpenAICompatibleMeetingIntelligenceAvailabilityChecker:
    MeetingIntelligenceAvailabilityChecking
{
    private let client: any ProviderConnectionTesting

    init(client: any ProviderConnectionTesting) {
        self.client = client
    }

    func availability(
        for snapshot: OpenAICompatibleProviderSnapshot
    ) async -> MeetingIntelligenceAvailability {
        let model = snapshot.profile.llmModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model != "legacy-unconfigured-llm" else {
            return .unconfirmed(.placeholderModel)
        }
        guard !Task.isCancelled else {
            return .unconfirmed(.connectionFailed)
        }

        do {
            let report = try await client.testConnection(
                profile: snapshot.profile,
                apiKey: snapshot.apiKey
            )
            guard !Task.isCancelled else {
                return .unconfirmed(.connectionFailed)
            }
            guard report.supportsModelDiscovery else {
                return .unconfirmed(.discoveryUnsupported)
            }
            return report.models.contains(model)
                ? .confirmed
                : .unconfirmed(.modelNotAdvertised)
        } catch ProviderConnectionError.authenticationRejected {
            return .unconfirmed(.authenticationRejected)
        } catch {
            return .unconfirmed(.connectionFailed)
        }
    }
}
