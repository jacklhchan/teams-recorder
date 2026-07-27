import Foundation

enum RecordingStorageDecision: Equatable {
    case normal
    case warn
    case audioOnly
    case stop
}

struct RecordingStoragePolicy {
    static let warningBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    static let videoMinimumBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    static let audioStopBytes: Int64 = 256 * 1_024 * 1_024

    let audioStopBytes: Int64

    init(audioStopBytes: Int64 = Self.audioStopBytes) {
        self.audioStopBytes = audioStopBytes
    }

    func decision(availableBytes: Int64) -> RecordingStorageDecision {
        if availableBytes < audioStopBytes {
            return .stop
        }
        if availableBytes < Self.videoMinimumBytes {
            return .audioOnly
        }
        if availableBytes < Self.warningBytes {
            return .warn
        }
        return .normal
    }
}

protocol VolumeCapacityProviding {
    func availableBytes(onVolumeContaining url: URL) throws -> Int64
}

enum RecordingStorageError: Error, Equatable {
    case capacityUnavailable
}

struct SelectedVolumeCapacityProvider: VolumeCapacityProviding {
    private let capacityLookup: (URL) throws -> Int64?

    init(capacityLookup: @escaping (URL) throws -> Int64? = Self.importantUsageCapacity) {
        self.capacityLookup = capacityLookup
    }

    func availableBytes(onVolumeContaining url: URL) throws -> Int64 {
        guard let availableBytes = try capacityLookup(url) else {
            throw RecordingStorageError.capacityUnavailable
        }
        return availableBytes
    }

    private static func importantUsageCapacity(for url: URL) throws -> Int64? {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage.map { Int64($0) }
    }
}
