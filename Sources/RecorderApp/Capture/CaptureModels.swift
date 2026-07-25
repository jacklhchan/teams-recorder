import Foundation

enum CaptureMode: String, Codable, CaseIterable {
    case allSystemAudio
    case selectedApplication
}

struct CaptureApplication: Identifiable, Codable, Hashable {
    let processID: pid_t
    let bundleIdentifier: String
    let name: String
    var id: String { bundleIdentifier }
}

struct CaptureSelection: Codable, Equatable {
    var mode: CaptureMode
    var selectedBundleIdentifier: String?
}

enum ResolvedCaptureSelection: Equatable {
    case allSystemAudio
    case application(CaptureApplication)
    case disconnected(String)
}
