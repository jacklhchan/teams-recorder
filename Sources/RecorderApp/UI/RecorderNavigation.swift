import AppKit
import SwiftUI

enum RecorderDestination: String, CaseIterable, Identifiable, Hashable {
    case record
    case recordings
    case settings

    var id: Self { self }

    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .record: "record.circle"
        case .recordings: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }
}

struct RecorderDestinationAccessibilityMarker: NSViewRepresentable {
    let identifier: String
    let label: String?

    init(identifier: String, label: String? = nil) {
        self.identifier = identifier
        self.label = label
    }

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        nsView.setAccessibilityIdentifier(identifier)
        nsView.setAccessibilityLabel(label)
    }
}

struct RecorderNavigationState: Equatable {
    var selection: RecorderDestination
    private(set) var pendingDestination: RecorderDestination?

    mutating func select(
        _ destination: RecorderDestination,
        hasUnsavedChanges: Bool
    ) {
        if hasUnsavedChanges && destination != selection {
            pendingDestination = destination
        } else {
            selection = destination
            pendingDestination = nil
        }
    }

    mutating func keepEditing() {
        pendingDestination = nil
    }

    mutating func discardAndNavigate() {
        if let pendingDestination {
            selection = pendingDestination
        }
        pendingDestination = nil
    }
}
