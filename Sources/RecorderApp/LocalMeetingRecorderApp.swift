import AppKit
import SwiftUI

@main
struct LocalMeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Local Meeting Recorder", id: "main") {
            if CommandLine.arguments.contains("--teams-screen-viability-probe") {
                TeamsCaptureViabilityProbeView()
            } else {
                ContentView(model: appDelegate.runtime.model)
                    .background(
                        MainWindowIdentifierView()
                            .frame(width: 0, height: 0)
                    )
            }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("Recording") {
                Button("Start / Stop Recording") {
                    NSApp.sendAction(#selector(AppCommands.startStopRecording), to: nil, from: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

@objc
private protocol AppCommands {
    func startStopRecording()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtimeStorage: AppRuntime?

    @MainActor
    var runtime: AppRuntime {
        if let runtimeStorage {
            return runtimeStorage
        }
        let runtime = AppRuntime()
        runtimeStorage = runtime
        return runtime
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            self.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        mainWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeStorage?.shutdown()
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first {
            $0.identifier == .localMeetingRecorderMain
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    static let localMeetingRecorderMain =
        NSUserInterfaceItemIdentifier("local-meeting-recorder-main")
}

private struct MainWindowIdentifierView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MainWindowIdentifierNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class MainWindowIdentifierNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = .localMeetingRecorderMain
    }
}
