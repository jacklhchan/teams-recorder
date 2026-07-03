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
    @Published var playingSessionID: RecordingSession.ID?
    @Published var playbackProgress: TimeInterval = 0
    @Published var playbackDuration: TimeInterval = 0
    @Published var isPlaybackActive = false
    @Published var transcribingSessionID: RecordingSession.ID?
    @Published var transcriptionStatus: String = ""
    @Published var lastTranscriptionSessionID: RecordingSession.ID?
    @Published var lastTranscriptionStatus: String = ""
    @Published var lastTranscriptionDidFail = false
    @Published var transcriptURLsBySessionID: [RecordingSession.ID: URL] = [:]
    @Published var transcriptLogURLsBySessionID: [RecordingSession.ID: URL] = [:]

    let recorder = RecordingEngine()
    private lazy var hotKeyManager = GlobalHotKeyManager { [weak self] in
        self?.toggleRecorderMicMute(source: "Hotkey")
    }
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var transcriptionProcess: Process?

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
            stopPlayback(resetStatus: false)
            let player = try AVAudioPlayer(contentsOf: session.recordingURL)
            audioPlayer = player
            playingSessionID = session.id
            playbackProgress = 0
            playbackDuration = player.duration
            isPlaybackActive = true
            audioPlayer?.play()
            startPlaybackTimer()
            statusMessage = "Playing \(session.displayName)"
        } catch {
            statusMessage = "Playback failed: \(error.localizedDescription)"
        }
    }

    func stopPlayback(resetStatus: Bool = true) {
        audioPlayer?.stop()
        audioPlayer = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        playingSessionID = nil
        playbackProgress = 0
        playbackDuration = 0
        isPlaybackActive = false
        if resetStatus {
            statusMessage = recorder.isRecording ? "Recording" : "Monitoring"
        }
    }

    func seekPlayback(to time: TimeInterval) {
        guard let audioPlayer else { return }
        let clamped = max(0, min(time, audioPlayer.duration))
        audioPlayer.currentTime = clamped
        playbackProgress = clamped
        if !audioPlayer.isPlaying {
            audioPlayer.play()
            isPlaybackActive = true
            startPlaybackTimer()
        }
    }

    func open(session: RecordingSession) {
        NSWorkspace.shared.open(session.folderURL)
    }

    func transcribe(session: RecordingSession) {
        guard transcribingSessionID == nil else {
            statusMessage = "A transcription is already running."
            return
        }

        let scriptURL = Bundle.main.resourceURL?.appendingPathComponent("transcribe-qwen-asr.sh")
            ?? URL(fileURLWithPath: "/Users/apple/Documents/recorder/scripts/transcribe-qwen-asr.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            statusMessage = "Missing transcription launcher: \(scriptURL.path)"
            return
        }

        transcribingSessionID = session.id
        lastTranscriptionSessionID = session.id
        lastTranscriptionStatus = "Starting Qwen ASR. First run may download the 8-bit model."
        lastTranscriptionDidFail = false
        transcriptionStatus = "Starting Qwen ASR. First run may download the 8-bit model."
        statusMessage = "Opening oMLX and starting transcription"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, session.recordingURL.path, session.folderURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        transcriptionProcess = process

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.handleTranscriptionOutput(text, session: session)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.transcriptionProcess = nil
                self?.transcribingSessionID = nil
                if process.terminationStatus == 0 {
                    self?.transcriptionStatus = "Transcription complete"
                    self?.lastTranscriptionStatus = "Transcription complete"
                    self?.lastTranscriptionDidFail = false
                    self?.statusMessage = "Transcription complete"
                } else {
                    self?.transcriptionStatus = "Transcription failed"
                    self?.lastTranscriptionStatus = "Transcription failed with exit code \(process.terminationStatus). Open the ASR log for details."
                    self?.lastTranscriptionDidFail = true
                    self?.statusMessage = "Transcription failed with exit code \(process.terminationStatus). Open the ASR log for details."
                }
            }
        }

        do {
            try process.run()
        } catch {
            transcribingSessionID = nil
            transcriptionProcess = nil
            transcriptionStatus = "Transcription launch failed"
            statusMessage = "Transcription launch failed: \(error.localizedDescription)"
        }
    }

    func openTranscript(for session: RecordingSession) {
        if let url = transcriptURLsBySessionID[session.id] {
            NSWorkspace.shared.open(url)
            return
        }

        let expected = session.folderURL.appendingPathComponent("transcript_qwen3_asr_1_7b_8bit_yue_trad.txt")
        if FileManager.default.fileExists(atPath: expected.path) {
            transcriptURLsBySessionID[session.id] = expected
            NSWorkspace.shared.open(expected)
        } else {
            statusMessage = "No transcript found for \(session.displayName)"
        }
    }

    func openTranscriptLog(for session: RecordingSession) {
        if let url = transcriptLogURLsBySessionID[session.id] {
            NSWorkspace.shared.open(url)
            return
        }

        let expected = session.folderURL.appendingPathComponent("transcription_qwen_asr.log")
        if FileManager.default.fileExists(atPath: expected.path) {
            transcriptLogURLsBySessionID[session.id] = expected
            NSWorkspace.shared.open(expected)
        } else {
            statusMessage = "No ASR log found for \(session.displayName)"
        }
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
                playingSessionID = nil
                playbackProgress = 0
                playbackDuration = audioPlayer?.duration ?? 0
                isPlaybackActive = true
                audioPlayer?.play()
                startPlaybackTimer()
                statusMessage = "Test saved and playing: \(result.health.summary)"
            } catch {
                statusMessage = "Test saved, playback failed: \(error.localizedDescription)"
            }
        }
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let audioPlayer = self.audioPlayer else { return }
                self.playbackProgress = audioPlayer.currentTime
                self.playbackDuration = audioPlayer.duration
                if !audioPlayer.isPlaying {
                    self.playbackTimer?.invalidate()
                    self.playbackTimer = nil
                    self.isPlaybackActive = false
                }
            }
        }
    }

    private func handleTranscriptionOutput(_ text: String, session: RecordingSession) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if let lastUsefulLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            transcriptionStatus = lastUsefulLine
            lastTranscriptionStatus = lastUsefulLine
        }

        for line in lines where line.hasPrefix("TRANSCRIPT_PATH=") {
            let path = String(line.dropFirst("TRANSCRIPT_PATH=".count))
            let url = URL(fileURLWithPath: path)
            transcriptURLsBySessionID[session.id] = url
            statusMessage = "Transcript saved: \(url.lastPathComponent)"
        }

        for line in lines where line.hasPrefix("LOG_PATH=") {
            let path = String(line.dropFirst("LOG_PATH=".count))
            transcriptLogURLsBySessionID[session.id] = URL(fileURLWithPath: path)
        }
    }

    private func requestMicrophonePermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        permissionMessage = granted ? "" : "Microphone permission is required in System Settings."
        refreshRoutingChecks()
    }
}
