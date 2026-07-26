import XCTest
@testable import RecorderApp

final class VirtualMicStatusTests: XCTestCase {
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
