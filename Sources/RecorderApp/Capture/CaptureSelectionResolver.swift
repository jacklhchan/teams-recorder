import Foundation

enum CaptureSelectionResolver {
    static func resolve(
        selection: CaptureSelection,
        availableApplications: [CaptureApplication],
        previousResolution: ResolvedCaptureSelection? = nil,
        reconnect: Bool = false
    ) -> ResolvedCaptureSelection {
        guard selection.mode == .selectedApplication else {
            return .allSystemAudio
        }
        let bundleID = selection.selectedBundleIdentifier ?? ""
        if case .disconnected(let disconnectedBundleID) = previousResolution,
           disconnectedBundleID == bundleID,
           !reconnect {
            return .disconnected(bundleID)
        }
        guard let app = availableApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else {
            return .disconnected(bundleID)
        }
        return .application(app)
    }
}
