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
    func present(
        presentation: PlaybackPresentationModel,
        togglePlayback: @escaping @MainActor () -> Void,
        stopPlayback: @escaping @MainActor () -> Void,
        seekPlayback: @escaping @MainActor (TimeInterval) -> Void,
        revealRecording: @escaping @MainActor () -> Void,
        setVolume: @escaping @MainActor (Float) -> Void,
        setRate: @escaping @MainActor (Float) -> Void
    )
    func dismiss()
}

extension PlaybackWindowPresenting {
    func present(
        presentation: PlaybackPresentationModel,
        togglePlayback: @escaping @MainActor () -> Void,
        stopPlayback: @escaping @MainActor () -> Void,
        seekPlayback: @escaping @MainActor (TimeInterval) -> Void,
        revealRecording _: @escaping @MainActor () -> Void,
        setVolume _: @escaping @MainActor (Float) -> Void,
        setRate _: @escaping @MainActor (Float) -> Void
    ) {
        present(
            presentation: presentation,
            togglePlayback: togglePlayback,
            stopPlayback: stopPlayback,
            seekPlayback: seekPlayback
        )
    }
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
                width: 720,
                height: 360
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
        window.contentMinSize = NSSize(width: 600, height: 300)
    }

    func present(
        presentation: PlaybackPresentationModel,
        togglePlayback: @escaping @MainActor () -> Void,
        stopPlayback: @escaping @MainActor () -> Void,
        seekPlayback: @escaping @MainActor (TimeInterval) -> Void
    ) {
        present(
            presentation: presentation,
            togglePlayback: togglePlayback,
            stopPlayback: stopPlayback,
            seekPlayback: seekPlayback,
            revealRecording: {},
            setVolume: { _ in },
            setRate: { _ in }
        )
    }

    func present(
        presentation: PlaybackPresentationModel,
        togglePlayback: @escaping @MainActor () -> Void,
        stopPlayback: @escaping @MainActor () -> Void,
        seekPlayback: @escaping @MainActor (TimeInterval) -> Void,
        revealRecording: @escaping @MainActor () -> Void,
        setVolume: @escaping @MainActor (Float) -> Void,
        setRate: @escaping @MainActor (Float) -> Void
    ) {
        guard let session = presentation.session else { return }
        let playbackPresentation = RecordingPlaybackPresentation.make(
            session: session,
            progress: presentation.progress,
            duration: presentation.duration
        )
        self.stopPlayback = stopPlayback
        window.title = "Playing \(session.displayName)"
        window.contentView = NSHostingView(
            rootView: PlaybackWindowView(
                presentation: presentation,
                togglePlayback: togglePlayback,
                seekPlayback: seekPlayback,
                revealRecording: revealRecording,
                setVolume: setVolume,
                setRate: setRate
            )
        )

        window.contentMinSize = playbackPresentation.minimumContentSize
        window.setContentSize(playbackPresentation.defaultContentSize)
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
    let seekPlayback: @MainActor (TimeInterval) -> Void
    let revealRecording: @MainActor () -> Void
    let setVolume: @MainActor (Float) -> Void
    let setRate: @MainActor (Float) -> Void

    var body: some View {
        Group {
            if let session = presentation.session {
                let playbackPresentation = RecordingPlaybackPresentation.make(
                    session: session,
                    progress: presentation.progress,
                    duration: presentation.duration
                )
                RecordingPlaybackView(
                    session: session,
                    player: presentation.player,
                    progress: presentation.progress,
                    duration: presentation.duration,
                    isPlaying: presentation.isPlaying,
                    togglePlayback: togglePlayback,
                    seekPlayback: seekPlayback,
                    revealRecording: revealRecording,
                    setVolume: setVolume,
                    setRate: setRate
                )
                .frame(
                    minWidth: playbackPresentation.minimumContentSize.width,
                    minHeight: playbackPresentation.minimumContentSize.height
                )
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
