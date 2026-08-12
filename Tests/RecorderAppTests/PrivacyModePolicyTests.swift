import XCTest
@testable import RecorderApp

@MainActor
final class PrivacyModePolicyTests: XCTestCase {
    func testAbsentPreferenceDefaultsToDisabledAndAllowsThirdPartyProcessing() {
        let defaults = makeDefaults()

        let policy = PrivacyModePolicy(defaults: defaults)

        XCTAssertFalse(policy.isEnabled)
        XCTAssertEqual(policy.admitThirdPartyProcessing(), .allowed)
    }

    func testEnabledPreferencePersistsAndBlocksThirdPartyProcessingAfterReload() {
        let defaults = makeDefaults()
        let policy = PrivacyModePolicy(defaults: defaults)
        policy.setEnabled(true)

        let reloadedPolicy = PrivacyModePolicy(defaults: defaults)

        XCTAssertTrue(reloadedPolicy.isEnabled)
        XCTAssertEqual(reloadedPolicy.admitThirdPartyProcessing(), .blockedLocalOnly)
    }

    func testDisabledPreferencePersistsAndAllowsThirdPartyProcessingAfterReload() {
        let defaults = makeDefaults()
        let policy = PrivacyModePolicy(defaults: defaults)
        policy.setEnabled(true)
        policy.setEnabled(false)

        let reloadedPolicy = PrivacyModePolicy(defaults: defaults)

        XCTAssertFalse(reloadedPolicy.isEnabled)
        XCTAssertEqual(reloadedPolicy.admitThirdPartyProcessing(), .allowed)
    }

    func testLocalOnlyMessageIsStableAndProviderAgnostic() {
        XCTAssertEqual(
            PrivacyModePolicy.localOnlyMessage,
            "Privacy Mode is on. This action stays local and will not contact an AI provider."
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PrivacyModePolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
