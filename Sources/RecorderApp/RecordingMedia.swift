import CoreGraphics
import Darwin
import Foundation

enum RecordingMediaKind: String, Codable, Hashable, Sendable {
    case audio
    case video
}

struct RecordedScreenInterval: Codable, Equatable, Hashable, Sendable {
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
}

struct RecordedTeamsWindowIdentity: Codable, Equatable, Hashable, Sendable {
    let processID: pid_t
    let windowID: CGWindowID
    let title: String
}

enum RecordingRecoveryState: String, Codable, Hashable, Sendable {
    case none
    case videoLostAudioPreserved
    case recoveredAfterInterruption
}
