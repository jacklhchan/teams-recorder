import AppKit

enum FloatingPanelPresentationState: Equatable {
    case expanded
    case collapsed

    var toggleLabel: String {
        self == .expanded
            ? "Collapse floating window"
            : "Expand floating window"
    }

    var accessibilityValue: String {
        self == .expanded ? "Expanded" : "Collapsed"
    }
}

enum FloatingPanelLayout {
    static let collapsedSize = NSSize(width: 132, height: 40)

    static func frame(
        preservingTopRightOf current: NSRect,
        targetSize: NSSize
    ) -> NSRect {
        NSRect(
            x: current.maxX - targetSize.width,
            y: current.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    static func frame(
        preservingTopRightOf current: NSRect,
        targetContentSize: NSSize,
        in window: NSWindow
    ) -> NSRect {
        let targetFrame = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetContentSize)
        )
        return frame(
            preservingTopRightOf: current,
            targetSize: targetFrame.size
        )
    }
}
