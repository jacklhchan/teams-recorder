import XCTest
@testable import RecorderApp

final class VirtualMicStatusTests: XCTestCase {
    func testReadyPresentationOnlyClaimsObservableBridgeAndMuteState() {
        XCTAssertEqual(
            VirtualMicStatusPresentation.make(
                installation: .ready,
                publisher: .ready,
                inputMuteControlAvailable: true
            ),
            .init(
                title: "Virtual mic active",
                detail: "Recorder mute controls output",
                tone: .ready
            )
        )
    }

    func testUnavailablePublisherKeepsDriverStatusActionable() {
        XCTAssertEqual(
            VirtualMicStatusPresentation.make(
                installation: .ready,
                publisher: .unavailable,
                inputMuteControlAvailable: false
            ),
            .init(
                title: "Bridge unavailable",
                detail: "Local recording continues",
                tone: .warning
            )
        )
    }

    func testReadyPresentationUsesAppMuteCopyWhenInputHandlerIsUnavailable() {
        XCTAssertEqual(
            VirtualMicStatusPresentation.make(
                installation: .ready,
                publisher: .ready,
                inputMuteControlAvailable: false
            ),
            .init(
                title: "Virtual mic active",
                detail: "App mute controls output",
                tone: .ready
            )
        )
    }

    func testReadyDriverWithStoppedPublisherIsIdle() {
        XCTAssertEqual(
            VirtualMicStatusPresentation.make(
                installation: .ready,
                publisher: .stopped,
                inputMuteControlAvailable: true
            ),
            .init(
                title: "Driver ready",
                detail: "Virtual mic idle",
                tone: .neutral
            )
        )
    }

    func testEnumeratedRemovedDriverRequiresRestart() {
        XCTAssertEqual(
            VirtualMicStatusPresentation.make(
                installation: .removalNeedsReboot,
                publisher: .stopped,
                inputMuteControlAvailable: false
            ),
            .init(
                title: "Restart required",
                detail: "Virtual microphone removal pending",
                tone: .warning
            )
        )
    }

    func testInstalledDriverThatIsNotEnumeratedRequiresRestart() {
        XCTAssertEqual(
            VirtualMicStatusPresentation.make(
                installation: .installedNeedsReboot,
                publisher: .stopped,
                inputMuteControlAvailable: true
            ),
            .init(
                title: "Restart required",
                detail: "Virtual microphone installed",
                tone: .warning
            )
        )
    }

    func testInstallationUsesExactDriverPathAndDeviceUID() {
        XCTAssertEqual(
            VirtualMicInstallation.driverURL.path,
            "/Library/Audio/Plug-Ins/HAL/LocalRecorderVirtualMic.driver"
        )
        XCTAssertEqual(
            VirtualMicInstallation.deviceUID,
            "local.meeting.recorder.virtual-mic.v1"
        )
    }

    func testStateRequiresBothBundleAndCoreAudioEnumeration() {
        XCTAssertEqual(
            VirtualMicInstallation.state(
                bundleExists: false,
                enumeratedDeviceUIDs: []
            ),
            .absent
        )
        XCTAssertEqual(
            VirtualMicInstallation.state(
                bundleExists: true,
                enumeratedDeviceUIDs: []
            ),
            .installedNeedsReboot
        )
        XCTAssertEqual(
            VirtualMicInstallation.state(
                bundleExists: true,
                enumeratedDeviceUIDs: [VirtualMicInstallation.deviceUID]
            ),
            .ready
        )
        XCTAssertEqual(
            VirtualMicInstallation.state(
                bundleExists: false,
                enumeratedDeviceUIDs: [VirtualMicInstallation.deviceUID]
            ),
            .removalNeedsReboot
        )
    }

    func testCurrentStateUsesInjectedFilesystemAndDeviceProviders() {
        var observedPath: String?
        let state = VirtualMicInstallation.currentState(
            fileExists: { path in
                observedPath = path
                return true
            },
            inputDeviceUIDs: {
                ["other.device", VirtualMicInstallation.deviceUID]
            }
        )

        XCTAssertEqual(observedPath, VirtualMicInstallation.driverURL.path)
        XCTAssertEqual(state, .ready)
    }
}
