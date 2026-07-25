import XCTest
@testable import RecorderApp

final class CaptureSelectionResolverTests: XCTestCase {
    func testSelectionDefaultsToAllSystemAudio() {
        XCTAssertEqual(CaptureSelection().mode, .allSystemAudio)
    }

    func testAllSystemAudioDoesNotRequireAnApplication() {
        let result = CaptureSelectionResolver.resolve(
            selection: .init(mode: .allSystemAudio),
            availableApplications: []
        )
        XCTAssertEqual(result, .allSystemAudio)
    }

    func testSelectedAppResolvesExactBundleIdentifier() {
        let teams = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let result = CaptureSelectionResolver.resolve(
            selection: .init(mode: .selectedApplication,
                             selectedBundleIdentifier: teams.bundleIdentifier),
            availableApplications: [teams]
        )
        XCTAssertEqual(result, .application(teams))
    }

    func testSelectedAppBecomesDisconnectedInsteadOfFallingBackToAllAudio() {
        let result = CaptureSelectionResolver.resolve(
            selection: .init(mode: .selectedApplication,
                             selectedBundleIdentifier: "com.microsoft.teams2"),
            availableApplications: []
        )
        XCTAssertEqual(result, .disconnected("com.microsoft.teams2"))
    }

    func testDisconnectedSelectionDoesNotAutoReconnectWhenApplicationReappears() {
        let selection = CaptureSelection(
            mode: .selectedApplication,
            selectedBundleIdentifier: "com.microsoft.teams2"
        )
        let teams = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let disconnected = CaptureSelectionResolver.resolve(
            selection: selection,
            availableApplications: []
        )

        let result = CaptureSelectionResolver.resolve(
            selection: selection,
            availableApplications: [teams],
            previousResolution: disconnected
        )

        XCTAssertEqual(result, .disconnected("com.microsoft.teams2"))
    }

    func testDisconnectedSelectionReconnectsOnlyWhenExplicitlyRequested() {
        let selection = CaptureSelection(
            mode: .selectedApplication,
            selectedBundleIdentifier: "com.microsoft.teams2"
        )
        let teams = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let disconnected = CaptureSelectionResolver.resolve(
            selection: selection,
            availableApplications: []
        )

        let result = CaptureSelectionResolver.resolve(
            selection: selection,
            availableApplications: [teams],
            previousResolution: disconnected,
            reconnect: true
        )

        XCTAssertEqual(result, .application(teams))
    }
}
