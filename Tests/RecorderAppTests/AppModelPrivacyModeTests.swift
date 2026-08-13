import Combine
import XCTest
@testable import RecorderApp

@MainActor
final class AppModelPrivacyModeTests: XCTestCase {
    func testInjectedPrivacyPolicyIsRetainedAndItsToggleProjectsAndPersists() {
        let defaults = makeDefaults()
        let policy = PrivacyModePolicy(defaults: defaults)
        let model = AppModel(
            defaults: defaults,
            privacyModePolicy: policy,
            performStartupWork: false
        )
        var publications = 0
        let observation = model.$privacyModeEnabled.dropFirst().sink { _ in
            publications += 1
        }
        defer { observation.cancel() }

        XCTAssertTrue(model.privacyModePolicy === policy)
        XCTAssertEqual(
            model.transcriptionFeature.thirdPartyProcessingAdmissionIdentity,
            ObjectIdentifier(policy)
        )
        XCTAssertEqual(
            model.meetingIntelligenceFeature.thirdPartyProcessingAdmissionIdentity,
            ObjectIdentifier(policy)
        )
        XCTAssertEqual(
            model.aiProviderSettingsModel.thirdPartyProcessingAdmissionIdentity,
            ObjectIdentifier(policy)
        )
        XCTAssertFalse(model.privacyModeEnabled)

        model.setPrivacyModeEnabled(true)

        XCTAssertTrue(model.privacyModeEnabled)
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(PrivacyModePolicy(defaults: defaults).isEnabled)
    }

    func testInitiallyEnabledPolicyForwardsPrivacyCancellationAfterComposition() {
        let defaults = makeDefaults()
        let policy = PrivacyModePolicy(defaults: defaults)
        policy.setEnabled(true)

        let model = AppModel(
            defaults: defaults,
            privacyModePolicy: policy,
            performStartupWork: false
        )

        XCTAssertTrue(model.privacyModeEnabled)
        XCTAssertEqual(
            model.aiProviderSettingsModel.status,
            PrivacyModePolicy.localOnlyMessage
        )
    }

    func testEnablingPrivacyDispatchesOneCancellationToEachAIBoundaryWithoutChangingRecordingOrMic() {
        let defaults = makeDefaults()
        let policy = PrivacyModePolicy(defaults: defaults)
        let model = AppModel(
            defaults: defaults,
            privacyModePolicy: policy,
            performStartupWork: false
        )
        var transcriptionCancellations = 0
        var intelligenceCancellations = 0
        var settingsCancellations = 0
        model.transcriptionFeature.onPrivacyModeCancellation = {
            transcriptionCancellations += 1
        }
        model.meetingIntelligenceFeature.onPrivacyModeCancellation = {
            intelligenceCancellations += 1
        }
        model.aiProviderSettingsModel.onPrivacyModeCancellation = {
            settingsCancellations += 1
        }
        let recordingBefore = model.recorder.isRecording
        let localMicMutedBefore = model.localMicMuted
        let nativeMicMutedBefore = model.nativeInputMicMuted

        model.setPrivacyModeEnabled(true)

        XCTAssertEqual(transcriptionCancellations, 1)
        XCTAssertEqual(intelligenceCancellations, 1)
        XCTAssertEqual(settingsCancellations, 1)
        XCTAssertEqual(model.recorder.isRecording, recordingBefore)
        XCTAssertEqual(model.localMicMuted, localMicMutedBefore)
        XCTAssertEqual(model.nativeInputMicMuted, nativeMicMutedBefore)

        model.setPrivacyModeEnabled(false)

        XCTAssertEqual(transcriptionCancellations, 1)
        XCTAssertEqual(intelligenceCancellations, 1)
        XCTAssertEqual(settingsCancellations, 1)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppModelPrivacyModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
