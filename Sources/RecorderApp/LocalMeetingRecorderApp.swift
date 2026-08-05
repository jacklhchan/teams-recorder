import AppKit
import SwiftUI

enum AppLaunchMode: Equatable {
    case interactive
    case backgroundControl

    init(arguments: [String]) {
        self = arguments.contains("--background-control")
            ? .backgroundControl
            : .interactive
    }
}

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
    private let launchMode = AppLaunchMode(arguments: CommandLine.arguments)

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
        switch launchMode {
        case .interactive:
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                self.mainWindow?.makeKeyAndOrderFront(nil)
            }
        case .backgroundControl:
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                self.mainWindow?.orderOut(nil)
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        sender.setActivationPolicy(.regular)
        sender.activate(ignoringOtherApps: true)
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
