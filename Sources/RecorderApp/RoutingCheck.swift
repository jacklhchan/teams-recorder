import Foundation
import SwiftUI

struct RoutingCheck: Identifiable, Hashable {
    enum Status: String {
        case ok
        case warning
        case error

        var color: Color {
            switch self {
            case .ok: .green
            case .warning: .orange
            case .error: .red
            }
        }

        var iconName: String {
            switch self {
            case .ok: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }
    }

    let id = UUID()
    let title: String
    let detail: String
    let status: Status
}
