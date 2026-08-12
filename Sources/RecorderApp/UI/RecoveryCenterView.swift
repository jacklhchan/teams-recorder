import SwiftUI

struct RecoveryCenterView: View {
    @ObservedObject var model: AppModel

    private var snapshot: RecoveryCenterSnapshot { model.recoveryCenterSnapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Recovery")
                .font(.largeTitle.bold())

            if snapshot.items.isEmpty {
                ContentUnavailableView(
                    "No local recordings need recovery",
                    systemImage: "tray"
                )
            } else {
                retainedCopies
                ForEach(RecoveryCenterGroup.allCases, id: \.self) { group in
                    let items = snapshot.items.filter { group.contains($0) }
                    if !items.isEmpty {
                        itemGroup(group, items: items)
                    }
                }
            }

            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier(RecorderActionID.recoveryCenterRoot)
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: "recorder.destination.recovery"
            )
        )
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: RecorderActionID.recoveryCenterRoot
            )
        )
    }

    @ViewBuilder
    private var retainedCopies: some View {
        if snapshot.presentation.retainedLocalCount > 0 {
            Label(
                "\(snapshot.presentation.retainedLocalCount) recordings retained locally",
                systemImage: "externaldrive.badge.exclamationmark"
            )
            .accessibilityIdentifier(RecorderActionID.recoveryCenterRetainedCount)
            .background(
                RecorderDestinationAccessibilityMarker(
                    identifier: RecorderActionID.recoveryCenterRetainedCount,
                    label: "\(snapshot.presentation.retainedLocalCount) recordings retained locally"
                )
            )
        }
    }

    private func itemGroup(
        _ group: RecoveryCenterGroup,
        items: [RecoveryCenterItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.title)
                .font(.title3.weight(.semibold))
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: "recorder.recovery.group.\(group.identifier)",
                        label: group.title
                    )
                )
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(sourceLabel(for: item.source))
                        .font(.headline)
                    Text(item.createdAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(group.stateLabel)
                        .font(.subheadline)
                    Text(item.safeStatusText)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier(
                    group == .needsAttention
                        ? RecorderActionID.recoveryCenterNeedsAttention
                        : "recorder.recovery.item.\(item.id.uuidString)"
                )
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: group == .needsAttention
                            ? RecorderActionID.recoveryCenterNeedsAttention
                            : "recorder.recovery.item.\(item.id.uuidString)",
                        label: "\(sourceLabel(for: item.source)) \(group.stateLabel) \(item.safeStatusText)"
                    )
                )
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            if snapshot.items.contains(where: \.canRetry) {
                Button("Retry Now", action: model.retryPendingRecordings)
                    .accessibilityIdentifier(RecorderActionID.recoveryCenterRetry)
                    .background(
                        RecorderDestinationAccessibilityMarker(
                            identifier: RecorderActionID.recoveryCenterRetry
                        )
                    )
            }
            if snapshot.presentation.retainedLocalCount > 0 {
                Button("Open Local Copies", action: model.openPendingRecordingsFolder)
                    .accessibilityIdentifier(RecorderActionID.recoveryCenterOpenLocal)
                    .background(
                        RecorderDestinationAccessibilityMarker(
                            identifier: RecorderActionID.recoveryCenterOpenLocal
                        )
                    )
            }
            if model.recordingDestinationState == .needsFolderAccess {
                Button("Restore Folder Access", action: model.chooseOutputFolder)
                    .accessibilityIdentifier(RecorderActionID.recoveryCenterRestoreAccess)
                    .background(
                        RecorderDestinationAccessibilityMarker(
                            identifier: RecorderActionID.recoveryCenterRestoreAccess
                        )
                    )
            }
        }
    }

    private func sourceLabel(for source: RecordingSource) -> String {
        switch source {
        case .manual: "Manual recording"
        case .teamsAutomatic: "Automatic meeting recording"
        case .imported: "Imported recording"
        }
    }
}

private enum RecoveryCenterGroup: CaseIterable {
    case publishingOrPending
    case waitingForDestination
    case needsAttention

    var title: String {
        switch self {
        case .publishingOrPending: "Publishing / Pending"
        case .waitingForDestination: "Waiting for destination"
        case .needsAttention: "Needs attention"
        }
    }

    var stateLabel: String { title }

    var identifier: String {
        switch self {
        case .publishingOrPending: "publishing-pending"
        case .waitingForDestination: "waiting-destination"
        case .needsAttention: "needs-attention"
        }
    }

    func contains(_ item: RecoveryCenterItem) -> Bool {
        switch (self, item.state) {
        case (.publishingOrPending, .publishingOrPending),
             (.waitingForDestination, .waitingForDestination),
             (.needsAttention, .needsAttention): true
        default: false
        }
    }
}
