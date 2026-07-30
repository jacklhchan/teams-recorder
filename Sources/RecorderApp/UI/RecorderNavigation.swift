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

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
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
