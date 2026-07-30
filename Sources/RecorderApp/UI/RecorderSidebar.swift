import SwiftUI

struct RecorderSidebar: View {
    @Binding var selection: RecorderDestination

    var body: some View {
        List(RecorderDestination.allCases, selection: $selection) { destination in
            Label(destination.title, systemImage: destination.systemImage)
                .tag(destination)
                .accessibilityIdentifier("recorder.navigation.\(destination.rawValue)")
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("recorder.workspace.sidebar")
    }
}
