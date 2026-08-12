import Combine
import Foundation

enum PrivacyModeAdmission: Equatable, Sendable {
    case allowed
    case blockedLocalOnly
}

@MainActor
protocol ThirdPartyProcessingAdmitting: Sendable {
    func admitThirdPartyProcessing() -> PrivacyModeAdmission
}

@MainActor
final class PrivacyModePolicy: ObservableObject, ThirdPartyProcessingAdmitting {
    static let defaultsKey = "privacyModeEnabled"
    static let localOnlyMessage = "Privacy Mode is on. This action stays local and will not contact an AI provider."

    @Published private(set) var isEnabled: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.defaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
    }

    func admitThirdPartyProcessing() -> PrivacyModeAdmission {
        isEnabled ? .blockedLocalOnly : .allowed
    }
}
