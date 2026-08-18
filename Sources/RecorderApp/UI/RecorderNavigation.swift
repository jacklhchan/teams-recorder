import AppKit
import SwiftUI

enum RecorderDestination: String, CaseIterable, Identifiable, Hashable {
    case record
    case recordings
    case health
    case recovery
    case settings

    var id: Self { self }

    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .record: "record.circle"
        case .recordings: "list.bullet.rectangle"
        case .health: "waveform.path.ecg"
        case .recovery: "tray.full"
        case .settings: "gearshape"
        }
    }
}

struct RecorderDestinationAccessibilityMarker: NSViewRepresentable {
    let identifier: String
    let label: String?
    let value: String?

    init(
        identifier: String,
        label: String? = nil,
        value: String? = nil
    ) {
        self.identifier = identifier
        self.label = label
        self.value = value
    }

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(value != nil)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(value)
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        nsView.setAccessibilityElement(value != nil)
        nsView.setAccessibilityIdentifier(identifier)
        nsView.setAccessibilityLabel(label)
        nsView.setAccessibilityValue(value)
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
