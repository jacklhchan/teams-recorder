import Foundation

enum CaptureSelectionResolver {
    static func resolve(
        selection: CaptureSelection,
        availableApplications: [CaptureApplication]
    ) -> ResolvedCaptureSelection {
        guard selection.mode == .selectedApplication else {
            return .allSystemAudio
        }
        let bundleID = selection.selectedBundleIdentifier ?? ""
        guard let app = availableApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else {
            return .disconnected(bundleID)
        }
        return .application(app)
    }
}
