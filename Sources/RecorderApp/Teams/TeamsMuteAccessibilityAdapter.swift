import ApplicationServices
import Foundation

enum TeamsMuteUnknownReason: Error, Equatable, Sendable {
    case inactive
    case accessibilityPermissionRequired
    case controlNotFound
    case ambiguousControls
    case accessibilityFailure
    case confirmationFailed
}

enum TeamsMicMuteState: Equatable, Sendable {
    case muted
    case unmuted
    case unknown(TeamsMuteUnknownReason)
}

protocol TeamsMuteControlling: Sendable {
    func readState(processID: pid_t) async -> TeamsMicMuteState
    func setMuted(_ muted: Bool, processID: pid_t) async -> TeamsMicMuteState
    @MainActor func requestPermission()
}

struct TeamsMuteControlDescriptor: Equatable, Sendable {
    let role: String?
    let identifier: String?
    let title: String?
    let description: String?
    let help: String?
    let value: String?
    let enabled: Bool
    let visible: Bool
}

enum TeamsMuteAccessibilityClassifier {
    static func classify(
        _ descriptors: [TeamsMuteControlDescriptor]
    ) -> TeamsMicMuteState {
        let states = descriptors.compactMap(classify)
        guard !states.isEmpty else {
            return .unknown(.controlNotFound)
        }
        guard states.count == 1 else {
            return .unknown(.ambiguousControls)
        }
        return states[0]
    }

    private static func classify(
        _ descriptor: TeamsMuteControlDescriptor
    ) -> TeamsMicMuteState? {
        guard descriptor.role == (kAXButtonRole as String),
              descriptor.enabled,
              descriptor.visible else { return nil }

        let evidence = [
            descriptor.identifier,
            descriptor.title,
            descriptor.description,
            descriptor.help,
            descriptor.value
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }

        if evidence.contains(where: isUnmuteAction) {
            return .muted
        }
        if evidence.contains(where: isMuteAction) {
            return .unmuted
        }
        return nil
    }

    private static func isMuteAction(_ value: String) -> Bool {
        value.caseInsensitiveCompare("Mute") == .orderedSame
            || value.caseInsensitiveCompare("Mute mic") == .orderedSame
            || value == "靜音"
            || value == "静音"
    }

    private static func isUnmuteAction(_ value: String) -> Bool {
        value.caseInsensitiveCompare("Unmute") == .orderedSame
            || value.caseInsensitiveCompare("Unmute mic") == .orderedSame
            || value == "取消靜音"
            || value == "取消静音"
    }
}

final class TeamsMuteAccessibilityAdapter: TeamsMuteControlling,
    @unchecked Sendable
{
    private struct Candidate {
        let element: AXUIElement
        let descriptor: TeamsMuteControlDescriptor
    }

    private static let maximumElementCount = 1_500
    private static let maximumDepth = 12

    func readState(processID: pid_t) async -> TeamsMicMuteState {
        await Task.detached(priority: .utility) {
            Self.readStateSynchronously(processID: processID)
        }.value
    }

    func setMuted(
        _ muted: Bool,
        processID: pid_t
    ) async -> TeamsMicMuteState {
        let desiredState: TeamsMicMuteState = muted ? .muted : .unmuted
        let actionResult = await Task.detached(priority: .utility) {
            Self.performActionIfNeeded(
                desiredState: desiredState,
                processID: processID
            )
        }.value

        if actionResult.isUnknown {
            return actionResult
        }
        if actionResult == desiredState {
            return desiredState
        }

        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let observed = await readState(processID: processID)
            if observed == desiredState {
                return observed
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .unknown(.confirmationFailed)
    }

    @MainActor
    func requestPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func readStateSynchronously(
        processID: pid_t
    ) -> TeamsMicMuteState {
        guard AXIsProcessTrusted() else {
            return .unknown(.accessibilityPermissionRequired)
        }
        return TeamsMuteAccessibilityClassifier.classify(
            candidates(processID: processID).map { $0.descriptor }
        )
    }

    private static func performActionIfNeeded(
        desiredState: TeamsMicMuteState,
        processID: pid_t
    ) -> TeamsMicMuteState {
        guard AXIsProcessTrusted() else {
            return .unknown(.accessibilityPermissionRequired)
        }
        let candidates = candidates(processID: processID)
        let state = TeamsMuteAccessibilityClassifier.classify(
            candidates.map { $0.descriptor }
        )
        guard state != desiredState else { return desiredState }
        guard !state.isUnknown, candidates.count == 1 else { return state }
        let error = AXUIElementPerformAction(
            candidates[0].element,
            kAXPressAction as CFString
        )
        return error == .success ? state : .unknown(.accessibilityFailure)
    }

    private static func candidates(
        processID: pid_t
    ) -> [Candidate] {
        let application = AXUIElementCreateApplication(processID)
        var queue: [(element: AXUIElement, depth: Int)] = [(application, 0)]
        var nextIndex = 0
        var visited: Set<CFHashCode> = []
        var result: [Candidate] = []

        while nextIndex < queue.count,
              visited.count < maximumElementCount {
            let node = queue[nextIndex]
            nextIndex += 1
            let identity = CFHash(node.element)
            guard visited.insert(identity).inserted else { continue }

            let descriptor = descriptor(for: node.element)
            if TeamsMuteAccessibilityClassifier.classify([descriptor])
                .isKnown {
                result.append(Candidate(
                    element: node.element,
                    descriptor: descriptor
                ))
            }

            guard node.depth < maximumDepth else { continue }
            guard let children = children(of: node.element) else {
                continue
            }
            queue.append(contentsOf: children.map { ($0, node.depth + 1) })
        }
        return result
    }

    private static func descriptor(
        for element: AXUIElement
    ) -> TeamsMuteControlDescriptor {
        TeamsMuteControlDescriptor(
            role: stringAttribute(kAXRoleAttribute, from: element),
            identifier: stringAttribute(kAXIdentifierAttribute, from: element),
            title: stringAttribute(kAXTitleAttribute, from: element),
            description: stringAttribute(
                kAXDescriptionAttribute,
                from: element
            ),
            help: stringAttribute(kAXHelpAttribute, from: element),
            value: stringAttribute(kAXValueAttribute, from: element),
            enabled: boolAttribute(kAXEnabledAttribute, from: element) ?? false,
            visible: !(boolAttribute("AXHidden", from: element) ?? false)
        )
    }

    private static func children(
        of element: AXUIElement
    ) -> [AXUIElement]? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        )
        guard error == .success else { return nil }
        return value as? [AXUIElement] ?? []
    }

    private static func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? Bool
    }
}

private extension TeamsMicMuteState {
    var isKnown: Bool {
        switch self {
        case .muted, .unmuted: true
        case .unknown: false
        }
    }

    var isUnknown: Bool { !isKnown }
}
