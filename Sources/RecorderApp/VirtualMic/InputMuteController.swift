import AVFAudio
import Foundation

@available(macOS 14.0, *)
protocol InputMuteControlling: AnyObject {
    var isMuted: Bool { get }
    func install(onChange: @escaping (Bool) -> Void) throws
    func setMuted(_ muted: Bool) throws
    func uninstall()
}

@available(macOS 14.0, *)
protocol InputMuteApplication {
    var isInputMuted: Bool { get }
    func setInputMuted(_ muted: Bool) throws
    func setInputMuteStateChangeHandler(_ handler: ((Bool) -> Bool)?) throws
}

@available(macOS 14.0, *)
final class InputMuteController: InputMuteControlling {
    private let application: InputMuteApplication
    private let notificationCenter: NotificationCenter
    private let notificationName: Notification.Name
    private let muteStateUserInfoKey: String
    private let applyMuteToAudioPaths: (Bool) -> Void

    private var observer: NSObjectProtocol?
    private var onChange: ((Bool) -> Void)?

    private(set) var isMuted: Bool

    init(
        application: InputMuteApplication = SystemInputMuteApplication(),
        notificationCenter: NotificationCenter = .default,
        notificationName: Notification.Name = AVAudioApplication.inputMuteStateChangeNotification,
        muteStateUserInfoKey: String = AVAudioApplication.muteStateKey,
        applyMuteToAudioPaths: @escaping (Bool) -> Void
    ) {
        self.application = application
        self.notificationCenter = notificationCenter
        self.notificationName = notificationName
        self.muteStateUserInfoKey = muteStateUserInfoKey
        self.applyMuteToAudioPaths = applyMuteToAudioPaths
        isMuted = application.isInputMuted
    }

    func install(onChange: @escaping (Bool) -> Void) throws {
        self.onChange = onChange

        guard observer == nil else {
            return
        }

        isMuted = application.isInputMuted
        applyMuteToAudioPaths(isMuted)

        try application.setInputMuteStateChangeHandler { [applyMuteToAudioPaths] muted in
            applyMuteToAudioPaths(muted)
            return true
        }

        observer = notificationCenter.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleMuteStateChange(notification)
        }
    }

    func setMuted(_ muted: Bool) throws {
        try application.setInputMuted(muted)
    }

    func uninstall() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }

        try? application.setInputMuteStateChangeHandler(nil)
        onChange = nil
    }

    private func handleMuteStateChange(_ notification: Notification) {
        guard let muted = muteState(from: notification) else {
            return
        }

        isMuted = muted
        onChange?(muted)
    }

    private func muteState(from notification: Notification) -> Bool? {
        if let muted = notification.userInfo?[muteStateUserInfoKey] as? Bool {
            return muted
        }
        if let muted = notification.userInfo?[muteStateUserInfoKey] as? NSNumber {
            return muted.boolValue
        }
        return nil
    }
}

@available(macOS 14.0, *)
private struct SystemInputMuteApplication: InputMuteApplication {
    var isInputMuted: Bool {
        AVAudioApplication.shared.isInputMuted
    }

    func setInputMuted(_ muted: Bool) throws {
        try AVAudioApplication.shared.setInputMuted(muted)
    }

    func setInputMuteStateChangeHandler(_ handler: ((Bool) -> Bool)?) throws {
        try AVAudioApplication.shared.setInputMuteStateChangeHandler(handler)
    }
}
