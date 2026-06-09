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

    let recorder = RecordingEngine()
    private lazy var hotKeyManager = GlobalHotKeyManager { [weak self] in
        self?.toggleRecorderMicMute(source: "Hotkey")
    }

    init() {
        refreshDevices()
        hotKeyManager.register()
        Task {
            await requestMicrophonePermission()
            refreshMonitoring()
        }
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
            recorder.stop()
            statusMessage = "Recording saved"
            return
        }

        do {
            try recorder.start(
                systemDevice: selectedSystemDevice,
                micDevice: selectedMicDevice,
                baseFolder: outputFolder
            )
            statusMessage = "Recording"
        } catch {
            statusMessage = error.localizedDescription
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
        }
    }

    func openRecordingFolder() {
        if let folder = recorder.outputFolder {
            NSWorkspace.shared.open(folder)
        } else {
            NSWorkspace.shared.open(outputFolder)
        }
    }

    func toggleRecorderMicMute(source: String = "Button") {
        recorder.toggleMicMute()
        statusMessage = "\(source): recorder mic \(recorder.micMuted ? "muted" : "active")"
    }

    private func requestMicrophonePermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        permissionMessage = granted ? "" : "Microphone permission is required in System Settings."
    }
}
