import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var selectedSystemDevice: AudioDevice?
    @Published var selectedMicDevice: AudioDevice?
    @Published var outputFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Downloads")
    @Published var statusMessage = "Ready"
    @Published var permissionMessage = ""
    @Published var sessions: [RecordingSession] = []
    @Published var routingChecks: [RoutingCheck] = []
    @Published var lastHealthReport: RecordingHealthReport?
    @Published var isRunningTestRecording = false

    let recorder = RecordingEngine()
    private lazy var hotKeyManager = GlobalHotKeyManager { [weak self] in
        self?.toggleRecorderMicMute(source: "Hotkey")
    }
    private var audioPlayer: AVAudioPlayer?

    init() {
        refreshDevices()
        hotKeyManager.register()
        Task {
            await requestMicrophonePermission()
            refreshMonitoring()
        }
        refreshSessions()
        refreshRoutingChecks()
    }

    func refreshDevices() {
        devices = AudioDeviceManager.inputDevices()

        if selectedSystemDevice == nil {
            selectedSystemDevice = devices.first { $0.name.localizedCaseInsensitiveContains("BlackHole") } ?? devices.first
        }

        if selectedMicDevice == nil {
            let defaultID = AudioDeviceManager.defaultInputDeviceID()
            selectedMicDevice = devices.first { $0.id == defaultID } ?? devices.first
        }

        refreshMonitoring()
        refreshRoutingChecks()
    }

    func refreshMonitoring() {
        do {
            try recorder.startMonitoring(systemDevice: selectedSystemDevice, micDevice: selectedMicDevice)
            statusMessage = recorder.isRecording ? "Recording" : "Monitoring"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func startOrStop() {
        if recorder.isRecording {
            finishRecording(playAfterStop: false)
            return
        }

        do {
            try recorder.start(
                systemDevice: selectedSystemDevice,
                micDevice: selectedMicDevice,
                baseFolder: outputFolder
            )
            statusMessage = "Recording"
            lastHealthReport = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func runTestRecording() {
        guard !isRunningTestRecording else { return }
        guard !recorder.isRecording else {
            statusMessage = "Stop the current recording before running a test."
            return
        }

        isRunningTestRecording = true
        lastHealthReport = nil
        do {
            try recorder.start(
                systemDevice: selectedSystemDevice,
                micDevice: selectedMicDevice,
                baseFolder: outputFolder,
                folderPrefix: "test"
            )
            statusMessage = "Test recording: 10 seconds"
        } catch {
            isRunningTestRecording = false
            statusMessage = error.localizedDescription
            return
        }

        Task {
            try? await Task.sleep(for: .seconds(10))
            guard self.isRunningTestRecording else { return }
            self.isRunningTestRecording = false
            self.finishRecording(playAfterStop: true)
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputFolder
        panel.prompt = "Use Folder"

        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
            refreshSessions()
            refreshRoutingChecks()
        }
    }

    func openRecordingFolder() {
        if let folder = recorder.outputFolder {
            NSWorkspace.shared.open(folder)
        } else {
            NSWorkspace.shared.open(outputFolder)
        }
    }

    func refreshSessions() {
        sessions = RecordingSessionStore.load(from: outputFolder)
    }

    func play(session: RecordingSession) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: session.recordingURL)
            audioPlayer?.play()
            statusMessage = "Playing \(session.displayName)"
        } catch {
            statusMessage = "Playback failed: \(error.localizedDescription)"
        }
    }

    func open(session: RecordingSession) {
        NSWorkspace.shared.open(session.folderURL)
    }

    func openAudioMIDISetup() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func refreshRoutingChecks() {
        let outputDevices = AudioDeviceManager.outputDevices()
        let blackHoleAvailable = devices.contains { $0.name.localizedCaseInsensitiveContains("BlackHole") }
        let selectedSystemIsBlackHole = selectedSystemDevice?.name.localizedCaseInsensitiveContains("BlackHole") == true
        let defaultOutput = outputDevices.first { $0.id == AudioDeviceManager.defaultOutputDeviceID() }
        let defaultSystemOutput = outputDevices.first { $0.id == AudioDeviceManager.defaultSystemOutputDeviceID() }
        let outputFolderWritable = FileManager.default.isWritableFile(atPath: outputFolder.path)

        routingChecks = [
            RoutingCheck(
                title: "BlackHole device",
                detail: blackHoleAvailable ? "BlackHole is installed and visible." : "Install or reload BlackHole 2ch.",
                status: blackHoleAvailable ? .ok : .error
            ),
            RoutingCheck(
                title: "System audio source",
                detail: selectedSystemIsBlackHole ? "Recorder is listening to BlackHole." : "Select BlackHole 2ch as System audio.",
                status: selectedSystemIsBlackHole ? .ok : .warning
            ),
            RoutingCheck(
                title: "macOS output",
                detail: defaultOutput?.name ?? "No default output device detected.",
                status: (defaultOutput?.name.localizedCaseInsensitiveContains("Multi-Output") == true) ? .ok : .warning
            ),
            RoutingCheck(
                title: "System alerts output",
                detail: defaultSystemOutput?.name ?? "No system output device detected.",
                status: (defaultSystemOutput?.name.localizedCaseInsensitiveContains("Multi-Output") == true) ? .ok : .warning
            ),
            RoutingCheck(
                title: "Save folder",
                detail: outputFolder.path,
                status: outputFolderWritable ? .ok : .error
            )
        ]
    }

    func toggleRecorderMicMute(source: String = "Button") {
        recorder.toggleMicMute()
        statusMessage = "\(source): recorder mic \(recorder.micMuted ? "muted" : "active")"
    }

    private func finishRecording(playAfterStop: Bool) {
        guard let result = recorder.stop() else {
            statusMessage = "No active recording."
            return
        }
        isRunningTestRecording = false
        lastHealthReport = result.health
        refreshSessions()
        statusMessage = "Recording saved: \(result.health.summary)"

        if playAfterStop {
            isRunningTestRecording = false
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: result.recordingURL)
                audioPlayer?.play()
                statusMessage = "Test saved and playing: \(result.health.summary)"
            } catch {
                statusMessage = "Test saved, playback failed: \(error.localizedDescription)"
            }
        }
    }

    private func requestMicrophonePermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        permissionMessage = granted ? "" : "Microphone permission is required in System Settings."
        refreshRoutingChecks()
    }
}
