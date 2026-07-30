import AppKit
import SwiftUI

@MainActor
protocol PlaybackWindowPresenting: AnyObject {
    func present(
        presentation: PlaybackPresentationModel,
        togglePlayback: @escaping @MainActor () -> Void,
        stopPlayback: @escaping @MainActor () -> Void,
        seekPlayback: @escaping @MainActor (TimeInterval) -> Void
    )
    func dismiss()
}

@MainActor
protocol PlaybackWindowPresenterFactory {
    func makePresenter() -> any PlaybackWindowPresenting
}

struct PlaybackWindowControllerFactory: PlaybackWindowPresenterFactory {
    nonisolated init() {}

    @MainActor
    func makePresenter() -> any PlaybackWindowPresenting {
        PlaybackWindowController()
    }
}

@MainActor
final class PlaybackWindowController:
    NSObject,
    PlaybackWindowPresenting,
    NSWindowDelegate
{
    private let window: NSWindow
    private var stopPlayback: (@MainActor () -> Void)?

    override init() {
        window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 760,
                height: 510
            ),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable
            ],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.isReleasedWhenClosed = false
        window.title = "Recording Playback"
        window.delegate = self
        window.contentMinSize = NSSize(width: 560, height: 110)
    }

    func present(
        presentation: PlaybackPresentationModel,
        togglePlayback: @escaping @MainActor () -> Void,
        stopPlayback: @escaping @MainActor () -> Void,
        seekPlayback: @escaping @MainActor (TimeInterval) -> Void
    ) {
        guard let session = presentation.session else { return }
        self.stopPlayback = stopPlayback
        window.title = "Playing \(session.displayName)"
        window.contentView = NSHostingView(
            rootView: PlaybackWindowView(
                presentation: presentation,
                togglePlayback: togglePlayback,
                stopPlayback: stopPlayback,
                seekPlayback: seekPlayback
            )
        )

        let contentSize = session.screenIntervals.isEmpty
            ? NSSize(width: 600, height: 150)
            : NSSize(width: 760, height: 510)
        window.contentMinSize = session.screenIntervals.isEmpty
            ? NSSize(width: 560, height: 110)
            : NSSize(width: 560, height: 380)
        window.setContentSize(contentSize)
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        stopPlayback = nil
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let stop = stopPlayback
        stopPlayback = nil
        stop?()
    }
}

@MainActor
private struct PlaybackWindowView: View {
    @ObservedObject var presentation: PlaybackPresentationModel
    let togglePlayback: @MainActor () -> Void
    let stopPlayback: @MainActor () -> Void
    let seekPlayback: @MainActor (TimeInterval) -> Void

    var body: some View {
        Group {
            if let session = presentation.session {
                RecordingPlaybackView(
                    session: session,
                    player: presentation.player,
                    progress: presentation.progress,
                    duration: presentation.duration,
                    isPlaying: presentation.isPlaying,
                    togglePlayback: togglePlayback,
                    stopPlayback: stopPlayback,
                    seekPlayback: seekPlayback
                )
                .padding(16)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(
            minWidth: 560,
            minHeight: presentation.session?.screenIntervals.isEmpty == false
                ? 470
                : 110
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
