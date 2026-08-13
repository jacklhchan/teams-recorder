import Foundation

@MainActor
final class LocalRecorderControlPolicy {
    static let defaultsKey = "localRecorderControlEnabled"

    private let defaults: UserDefaults
    private(set) var isEnabled: Bool
    var onChange: ((Bool) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.defaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
        onChange?(enabled)
    }
}
