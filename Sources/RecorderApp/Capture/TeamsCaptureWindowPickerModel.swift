import Foundation

struct TeamsCaptureWindowDescriptor: Equatable, Hashable, Identifiable {
    let windowID: UInt32
    let title: String
    let width: Int
    let height: Int
    let isOnScreen: Bool
    let windowLayer: Int

    var id: UInt32 { windowID }

    var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var area: Int {
        max(0, width) * max(0, height)
    }
}

struct TeamsCaptureWindowPickerResult: Equatable {
    let windowIDs: [UInt32]
    let selectedWindowID: UInt32?
    let status: String
    let isUsingAllWindowsFallback: Bool
}

enum TeamsCaptureWindowPickerModel {
    private static let minimumWidth = 320
    private static let minimumHeight = 180

    static func makeResult(
        descriptors: [TeamsCaptureWindowDescriptor],
        showAll: Bool,
        selectedWindowID: UInt32?
    ) -> TeamsCaptureWindowPickerResult {
        let rankedAll = descriptors.sorted(by: ranksBefore)
        let recommended = rankedAll.filter(isRecommended)
        let usesFallback = !showAll && recommended.isEmpty && !rankedAll.isEmpty
        let visible = showAll || usesFallback ? rankedAll : recommended
        let windowIDs = visible.map(\.windowID)
        let selected = selectedWindowID.flatMap {
            windowIDs.contains($0) ? $0 : nil
        } ?? windowIDs.first

        let status: String
        if rankedAll.isEmpty {
            status = "No windows owned by com.microsoft.teams2 were found."
        } else if showAll {
            status = "Showing all \(rankedAll.count) Teams \(windowNoun(rankedAll.count))."
        } else if usesFallback {
            status = "No likely meeting windows found; showing all \(rankedAll.count) Teams \(windowNoun(rankedAll.count))."
        } else {
            let hiddenCount = rankedAll.count - recommended.count
            status = "\(recommended.count) likely Teams \(windowNoun(recommended.count)); \(hiddenCount) internal or inactive \(windowNoun(hiddenCount)) hidden."
        }

        return TeamsCaptureWindowPickerResult(
            windowIDs: windowIDs,
            selectedWindowID: selected,
            status: status,
            isUsingAllWindowsFallback: usesFallback
        )
    }

    static func displayName(
        for descriptor: TeamsCaptureWindowDescriptor,
        includesWindowID: Bool
    ) -> String {
        let title = descriptor.normalizedTitle
        let role: String
        if title.caseInsensitiveCompare("Microsoft Teams") == .orderedSame {
            role = "Main Teams window"
        } else if title.caseInsensitiveCompare("Teams NRC") == .orderedSame {
            role = "Teams internal window (NRC)"
        } else if title.isEmpty {
            role = "Possible meeting or shared-content window"
        } else {
            role = title
        }

        let dimensions = "\(descriptor.width)x\(descriptor.height)"
        let base = "\(role) - \(dimensions)"
        return includesWindowID
            ? "\(base) - Window ID \(descriptor.windowID)"
            : base
    }

    private static func isRecommended(
        _ descriptor: TeamsCaptureWindowDescriptor
    ) -> Bool {
        descriptor.normalizedTitle.caseInsensitiveCompare("Teams NRC")
            != .orderedSame
            && descriptor.windowLayer == 0
            && descriptor.isOnScreen
            && descriptor.width >= minimumWidth
            && descriptor.height >= minimumHeight
    }

    private static func ranksBefore(
        _ lhs: TeamsCaptureWindowDescriptor,
        _ rhs: TeamsCaptureWindowDescriptor
    ) -> Bool {
        let lhsRole = roleRank(lhs)
        let rhsRole = roleRank(rhs)
        if lhsRole != rhsRole {
            return lhsRole < rhsRole
        }
        if lhs.area != rhs.area {
            return lhs.area > rhs.area
        }
        return lhs.windowID < rhs.windowID
    }

    private static func roleRank(
        _ descriptor: TeamsCaptureWindowDescriptor
    ) -> Int {
        let title = descriptor.normalizedTitle
        if title.caseInsensitiveCompare("Microsoft Teams") == .orderedSame {
            return 0
        }
        return title.isEmpty ? 2 : 1
    }

    private static func windowNoun(_ count: Int) -> String {
        count == 1 ? "window" : "windows"
    }
}
