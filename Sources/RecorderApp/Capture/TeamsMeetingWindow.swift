import CoreGraphics
import Foundation

struct TeamsWindowIdentity: Codable, Hashable, Sendable {
    let processID: pid_t
    let windowID: CGWindowID
}

struct TeamsWindowSnapshot: Identifiable, Equatable, Sendable {
    let identity: TeamsWindowIdentity
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    let layer: Int

    var id: TeamsWindowIdentity { identity }
}

struct TeamsWindowDescriptor: Identifiable, Equatable, Sendable {
    let identity: TeamsWindowIdentity
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    let layer: Int
    let firstSeenAt: Date
    let lastSurfacedAt: Date?

    var id: TeamsWindowIdentity { identity }
}

enum TeamsWindowConfidence: Int, Codable, Sendable {
    case low
    case medium
    case high
}

struct TeamsWindowMatch: Equatable, Sendable {
    let window: TeamsWindowDescriptor
    let confidence: TeamsWindowConfidence
}

enum TeamsWindowResolution: Equatable, Sendable {
    case ready(TeamsWindowMatch)
    case ambiguous([TeamsWindowDescriptor])
    case waiting
}

enum TeamsWindowRejectionReason: Hashable, Sendable {
    case utilityTitle
    case nonNormalLayer
    case insufficientWidth
    case insufficientHeight
    case insufficientArea
}

struct TeamsMeetingWindowResolver {
    static let minimumWidth: CGFloat = 640
    static let minimumHeight: CGFloat = 360
    static let minimumArea: CGFloat = 230_400
    static let ambiguityAreaRatio: CGFloat = 0.9
    static let utilityTitles: Set<String> = [
        "settings",
        "notification",
        "microsoft teams helper"
    ]

    private struct TrackedWindow {
        let firstSeenAt: Date
        var lastSurfacedAt: Date?
        var wasOnScreen: Bool
        var firstSeenMeetingGeneration: Int?
        var surfacedMeetingGeneration: Int?
    }

    private var trackedWindows: [TeamsWindowIdentity: TrackedWindow] = [:]
    private var currentIdentity: TeamsWindowIdentity?
    private var manualOverride: TeamsWindowIdentity?
    private var manualOverrideTitle: String?
    private var lastObservedTitles: [TeamsWindowIdentity: String] = [:]
    private var meetingWasActive = false
    private var meetingGeneration = 0

    static func rejectionReasons(for window: TeamsWindowSnapshot) -> Set<TeamsWindowRejectionReason> {
        var reasons: Set<TeamsWindowRejectionReason> = []
        if utilityTitles.contains(window.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            reasons.insert(.utilityTitle)
        }
        if window.layer != 0 {
            reasons.insert(.nonNormalLayer)
        }
        if window.frame.width < minimumWidth {
            reasons.insert(.insufficientWidth)
        }
        if window.frame.height < minimumHeight {
            reasons.insert(.insufficientHeight)
        }
        if window.frame.width * window.frame.height < minimumArea {
            reasons.insert(.insufficientArea)
        }
        return reasons
    }

    mutating func observe(
        _ windows: [TeamsWindowSnapshot],
        meetingActive: Bool,
        now: Date
    ) -> TeamsWindowResolution {
        if meetingActive && !meetingWasActive {
            meetingGeneration += 1
        }
        meetingWasActive = meetingActive

        var descriptors: [TeamsWindowIdentity: TeamsWindowDescriptor] = [:]
        lastObservedTitles = Dictionary(
            uniqueKeysWithValues: windows.map {
                ($0.identity, Self.normalizedTitle($0.title))
            }
        )
        for window in windows {
            var tracked = trackedWindows[window.identity] ?? TrackedWindow(
                firstSeenAt: now,
                lastSurfacedAt: window.isOnScreen ? now : nil,
                wasOnScreen: window.isOnScreen,
                firstSeenMeetingGeneration: meetingActive ? meetingGeneration : nil,
                surfacedMeetingGeneration: nil
            )

            if trackedWindows[window.identity] != nil,
               !tracked.wasOnScreen,
               window.isOnScreen {
                tracked.lastSurfacedAt = now
                if meetingActive {
                    tracked.surfacedMeetingGeneration = meetingGeneration
                }
            }
            tracked.wasOnScreen = window.isOnScreen
            trackedWindows[window.identity] = tracked
            descriptors[window.identity] = descriptor(for: window, tracked: tracked)
        }

        if let manualOverride {
            let exactResolution = resolution(
                for: manualOverride,
                descriptors: descriptors,
                windows: windows,
                manual: true
            )
            if case let .ready(match) = exactResolution {
                manualOverrideTitle = Self.normalizedTitle(match.window.title)
                return exactResolution
            }
            if let replacement = manualReplacement(
                for: manualOverride,
                descriptors: descriptors,
                windows: windows
            ) {
                self.manualOverride = replacement.identity
                manualOverrideTitle = Self.normalizedTitle(replacement.title)
                currentIdentity = replacement.identity
                return .ready(TeamsWindowMatch(window: replacement, confidence: .high))
            }
            return .waiting
        }

        guard meetingActive else {
            return .waiting
        }

        if let currentIdentity, descriptors[currentIdentity] != nil {
            return resolution(for: currentIdentity, descriptors: descriptors, windows: windows, manual: false)
        }
        currentIdentity = nil

        let candidates = windows.compactMap { window -> Candidate? in
            guard window.isOnScreen,
                  Self.rejectionReasons(for: window).isEmpty,
                  let descriptor = descriptors[window.identity],
                  let tracked = trackedWindows[window.identity] else {
                return nil
            }
            return Candidate(window: descriptor, meetingEraScore: meetingEraScore(for: tracked))
        }.sorted(by: Self.isPreferred)

        guard let first = candidates.first else {
            return .waiting
        }
        if let second = candidates.dropFirst().first,
           first.meetingEraScore == second.meetingEraScore,
           second.area >= first.area * Self.ambiguityAreaRatio {
            return .ambiguous([first.window, second.window])
        }

        currentIdentity = first.window.identity
        return .ready(TeamsWindowMatch(window: first.window, confidence: confidence(for: first.meetingEraScore)))
    }

    mutating func selectManualOverride(_ identity: TeamsWindowIdentity?) {
        guard identity != manualOverride else { return }
        manualOverride = identity
        currentIdentity = identity
        manualOverrideTitle = identity.flatMap { lastObservedTitles[$0] }
    }

    mutating func resetForApplicationRestart() {
        trackedWindows.removeAll()
        currentIdentity = nil
        manualOverride = nil
        manualOverrideTitle = nil
        lastObservedTitles.removeAll()
        meetingWasActive = false
        meetingGeneration = 0
    }

    private struct Candidate {
        let window: TeamsWindowDescriptor
        let meetingEraScore: Int

        var area: CGFloat { window.frame.width * window.frame.height }
    }

    private mutating func resolution(
        for identity: TeamsWindowIdentity,
        descriptors: [TeamsWindowIdentity: TeamsWindowDescriptor],
        windows: [TeamsWindowSnapshot],
        manual: Bool
    ) -> TeamsWindowResolution {
        guard let descriptor = descriptors[identity],
              let snapshot = windows.first(where: { $0.identity == identity }),
              snapshot.isOnScreen,
              Self.rejectionReasons(for: snapshot).isEmpty,
              let tracked = trackedWindows[identity] else {
            return .waiting
        }
        currentIdentity = identity
        let score = meetingEraScore(for: tracked)
        let matchConfidence = manual ? .high : confidence(for: score)
        return .ready(TeamsWindowMatch(window: descriptor, confidence: matchConfidence))
    }

    private func descriptor(for window: TeamsWindowSnapshot, tracked: TrackedWindow) -> TeamsWindowDescriptor {
        TeamsWindowDescriptor(
            identity: window.identity,
            title: window.title,
            frame: window.frame,
            isOnScreen: window.isOnScreen,
            layer: window.layer,
            firstSeenAt: tracked.firstSeenAt,
            lastSurfacedAt: tracked.lastSurfacedAt
        )
    }

    private func meetingEraScore(for tracked: TrackedWindow) -> Int {
        tracked.firstSeenMeetingGeneration == meetingGeneration ||
        tracked.surfacedMeetingGeneration == meetingGeneration ? 1 : 0
    }

    private func confidence(for score: Int) -> TeamsWindowConfidence {
        score > 0 ? .high : .medium
    }

    private func manualReplacement(
        for identity: TeamsWindowIdentity,
        descriptors: [TeamsWindowIdentity: TeamsWindowDescriptor],
        windows: [TeamsWindowSnapshot]
    ) -> TeamsWindowDescriptor? {
        guard let manualOverrideTitle, !manualOverrideTitle.isEmpty else { return nil }
        let replacements = windows.compactMap { window -> TeamsWindowDescriptor? in
            guard window.identity != identity,
                  window.identity.processID == identity.processID,
                  window.isOnScreen,
                  Self.rejectionReasons(for: window).isEmpty,
                  Self.normalizedTitle(window.title) == manualOverrideTitle else {
                return nil
            }
            return descriptors[window.identity]
        }
        return replacements.count == 1 ? replacements[0] : nil
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isPreferred(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.meetingEraScore != rhs.meetingEraScore {
            return lhs.meetingEraScore > rhs.meetingEraScore
        }
        if lhs.area != rhs.area {
            return lhs.area > rhs.area
        }
        if lhs.window.identity.processID != rhs.window.identity.processID {
            return lhs.window.identity.processID < rhs.window.identity.processID
        }
        return lhs.window.identity.windowID < rhs.window.identity.windowID
    }
}
