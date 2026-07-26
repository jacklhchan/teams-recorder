import Foundation
import XCTest
@testable import RecorderApp

final class InputMuteControllerTests: XCTestCase {
    func testInitialStateComesFromApplication() {
        let application = FakeInputMuteApplication(initiallyMuted: true)
        let controller = makeController(application: application)

        XCTAssertTrue(controller.isMuted)
    }

    func testInstallRegistersSingleHandlerAndAccessoryCallbackAppliesMuteSynchronously() throws {
        let application = FakeInputMuteApplication(initiallyMuted: false)
        var events: [String] = []
        let controller = makeController(
            application: application,
            applyMuteToAudioPaths: { muted in
                events.append("apply:\(muted)")
            }
        )

        try controller.install { muted in
            events.append("change:\(muted)")
        }

        XCTAssertEqual(application.handlerRegistrationCount, 1)
        XCTAssertEqual(application.lastRegisteredHandlerWasNil, false)

        let result = try XCTUnwrap(application.invokeAccessoryMute(true))
        XCTAssertTrue(result)
        XCTAssertEqual(events, ["apply:true"])
        XCTAssertFalse(controller.isMuted)
    }

    func testSetMutedCallsApplicationButDoesNotClaimStateBeforeNotification() throws {
        let application = FakeInputMuteApplication(initiallyMuted: false)
        let notificationCenter = NotificationCenter()
        var changes: [Bool] = []
        var applyCalls: [Bool] = []
        let controller = makeController(
            application: application,
            notificationCenter: notificationCenter,
            applyMuteToAudioPaths: { muted in
                applyCalls.append(muted)
            }
        )

        try controller.install { muted in
            changes.append(muted)
        }

        try controller.setMuted(true)

        XCTAssertEqual(application.setInputMutedCalls, [true])
        XCTAssertFalse(controller.isMuted)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertTrue(applyCalls.isEmpty)

        notificationCenter.post(
            name: .fakeInputMuteStateChange,
            object: nil,
            userInfo: [FakeInputMuteApplication.muteStateKey: true]
        )

        XCTAssertTrue(controller.isMuted)
        XCTAssertEqual(changes, [true])
        XCTAssertTrue(applyCalls.isEmpty)
    }

    func testSetMutedThrowRollsBackWithoutClaimingStateChange() throws {
        let application = FakeInputMuteApplication(initiallyMuted: false)
        application.setInputMutedError = FakeError.expectedFailure
        var changes: [Bool] = []
        var applyCalls: [Bool] = []
        let controller = makeController(
            application: application,
            applyMuteToAudioPaths: { muted in
                applyCalls.append(muted)
            }
        )

        try controller.install { muted in
            changes.append(muted)
        }

        XCTAssertThrowsError(try controller.setMuted(true))
        XCTAssertEqual(application.setInputMutedCalls, [true])
        XCTAssertFalse(controller.isMuted)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertTrue(applyCalls.isEmpty)
    }

    func testNotificationOnlyUpdatesObservationNotAudioGate() throws {
        let application = FakeInputMuteApplication(initiallyMuted: false)
        let notificationCenter = NotificationCenter()
        var changes: [Bool] = []
        var applyCalls: [Bool] = []
        let controller = makeController(
            application: application,
            notificationCenter: notificationCenter,
            applyMuteToAudioPaths: { muted in
                applyCalls.append(muted)
            }
        )

        try controller.install { muted in
            changes.append(muted)
        }

        notificationCenter.post(
            name: .fakeInputMuteStateChange,
            object: nil,
            userInfo: [FakeInputMuteApplication.muteStateKey: true]
        )

        XCTAssertTrue(controller.isMuted)
        XCTAssertEqual(changes, [true])
        XCTAssertTrue(applyCalls.isEmpty)
    }

    func testUninstallRemovesHandlerAndObserver() throws {
        let application = FakeInputMuteApplication(initiallyMuted: false)
        let notificationCenter = NotificationCenter()
        var changes: [Bool] = []
        var applyCalls: [Bool] = []
        let controller = makeController(
            application: application,
            notificationCenter: notificationCenter,
            applyMuteToAudioPaths: { muted in
                applyCalls.append(muted)
            }
        )

        try controller.install { muted in
            changes.append(muted)
        }
        controller.uninstall()

        XCTAssertEqual(application.handlerRegistrationCount, 2)
        XCTAssertEqual(application.lastRegisteredHandlerWasNil, true)
        XCTAssertNil(application.invokeAccessoryMute(true))

        notificationCenter.post(
            name: .fakeInputMuteStateChange,
            object: nil,
            userInfo: [FakeInputMuteApplication.muteStateKey: true]
        )

        XCTAssertFalse(controller.isMuted)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertTrue(applyCalls.isEmpty)
    }

    private func makeController(
        application: FakeInputMuteApplication,
        notificationCenter: NotificationCenter = NotificationCenter(),
        applyMuteToAudioPaths: @escaping (Bool) -> Void = { _ in }
    ) -> InputMuteController {
        InputMuteController(
            application: application,
            notificationCenter: notificationCenter,
            notificationName: .fakeInputMuteStateChange,
            muteStateUserInfoKey: FakeInputMuteApplication.muteStateKey,
            applyMuteToAudioPaths: applyMuteToAudioPaths
        )
    }
}

private extension Notification.Name {
    static let fakeInputMuteStateChange = Notification.Name("InputMuteControllerTests.fakeInputMuteStateChange")
}

private enum FakeError: Error {
    case expectedFailure
}

private final class FakeInputMuteApplication: InputMuteApplication {
    static let muteStateKey = "muteState"

    private(set) var isInputMuted: Bool
    private(set) var setInputMutedCalls: [Bool] = []
    private(set) var handlerRegistrationCount = 0
    private(set) var lastRegisteredHandlerWasNil = true
    var setInputMutedError: Error?

    private var handler: ((Bool) -> Bool)?

    init(initiallyMuted: Bool) {
        isInputMuted = initiallyMuted
    }

    func setInputMuted(_ muted: Bool) throws {
        setInputMutedCalls.append(muted)
        if let setInputMutedError {
            throw setInputMutedError
        }
    }

    func setInputMuteStateChangeHandler(_ handler: ((Bool) -> Bool)?) throws {
        handlerRegistrationCount += 1
        lastRegisteredHandlerWasNil = handler == nil
        self.handler = handler
    }

    func invokeAccessoryMute(_ muted: Bool) -> Bool? {
        handler?(muted)
    }
}
