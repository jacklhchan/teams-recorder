import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
    @Published var transcriptionStatesBySessionID: [RecordingSession.ID: TranscriptionState] = [:]
    @Published var isPreparingASRModel = false
    @Published var asrModelReady = false
    @Published var asrModelStatus = "Checking oMLX ASR server..."
    @Published var asrModelLogURL: URL?

    let recorder = RecordingEngine()
    private lazy var hotKeyManager = GlobalHotKeyManager { [weak self] in
        self?.toggleRecorderMicMute(source: "Hotkey")
    }
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var transcriptionProcess: Process?
    private var transcriptionCancellationRequested = false
    private var asrPrepareProcess: Process?

    init() {
        refreshDevices()
        hotKeyManager.register()
        Task {
            await requestMicrophonePermission()
            refreshMonitoring()
        }
        refreshSessions()
        refreshRoutingChecks()
        refreshASRModelStatus()
        prepareASRModelIfNeeded()
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
        let microphoneUID = selectedMicDevice?.uid
        Task {
            do {
                try await recorder.startMonitoring(
                    selection: .allSystemAudio,
                    microphoneUID: microphoneUID
                )
                statusMessage = recorder.isRecording ? "Recording" : "Monitoring"
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func startOrStop() {
        if recorder.isRecording {
            Task { await finishRecording(playAfterStop: false) }
            return
        }

        let microphoneUID = selectedMicDevice?.uid
        Task {
            do {
                try await recorder.start(
                    selection: .allSystemAudio,
                    microphoneUID: microphoneUID,
                    baseFolder: outputFolder
                )
                statusMessage = "Recording"
                lastHealthReport = nil
            } catch {
                statusMessage = error.localizedDescription
            }
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
        Task {
            let microphoneUID = selectedMicDevice?.uid
            do {
                try await recorder.start(
                    selection: .allSystemAudio,
                    microphoneUID: microphoneUID,
                    baseFolder: outputFolder,
                    folderPrefix: "test"
                )
                statusMessage = "Test recording: 10 seconds"
            } catch {
                isRunningTestRecording = false
                statusMessage = error.localizedDescription
                return
            }
            try? await Task.sleep(for: .seconds(10))
            guard self.isRunningTestRecording else { return }
            self.isRunningTestRecording = false
            await self.finishRecording(playAfterStop: true)
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

    func chooseAudioFileForTranscription() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ManualTranscriptionImporter.supportedExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Transcribe"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let importedSession = try ManualTranscriptionImporter.importAudioFile(url, into: outputFolder)
            refreshSessions()
            statusMessage = "Audio imported for transcription: \(url.lastPathComponent)"
            transcribe(session: importedSession)
        } catch {
            statusMessage = "Audio import failed: \(error.localizedDescription)"
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
        transcriptionStatesBySessionID = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            guard transcribingSessionID != session.id,
                  let state = try? TranscriptionStateStore.markInterruptedIfNeeded(in: session.folderURL) else {
                return nil
            }
            return (session.id, state)
        })
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
        guard asrModelReady else {
            prepareASRModelIfNeeded()
            statusMessage = "oMLX ASR server is still preparing. Wait until it is ready, then transcribe again."
            return
        }

        let scriptURL = Bundle.main.resourceURL?.appendingPathComponent("transcribe-qwen-asr.sh")
            ?? URL(fileURLWithPath: "/Users/apple/Documents/recorder/scripts/transcribe-qwen-asr.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            statusMessage = "Missing transcription launcher: \(scriptURL.path)"
            return
        }

        transcribingSessionID = session.id
        transcriptionCancellationRequested = false
        lastTranscriptionSessionID = session.id
        lastTranscriptionStatus = "Preparing transcription"
        lastTranscriptionDidFail = false
        transcriptionStatus = "Preparing transcription"
        statusMessage = "Preparing transcription"
        updateTranscriptionState(
            .init(phase: .queued, message: transcriptionStatus, startedAt: Date()),
            for: session
        )

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
                if self?.transcriptionCancellationRequested == true {
                    self?.transcriptionStatus = "Transcription cancelled"
                    self?.lastTranscriptionStatus = "Transcription cancelled"
                    self?.lastTranscriptionDidFail = false
                    self?.updateTranscriptionState(
                        .init(phase: .cancelled, message: "Transcription cancelled", startedAt: self?.transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
                        for: session
                    )
                    self?.statusMessage = "Transcription cancelled"
                } else if process.terminationStatus == 0 {
                    self?.transcriptionStatus = "Transcription complete"
                    self?.lastTranscriptionStatus = "Transcription complete"
                    self?.lastTranscriptionDidFail = false
                    self?.updateTranscriptionState(
                        .init(phase: .completed, message: "Transcription complete", startedAt: self?.transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
                        for: session
                    )
                    self?.statusMessage = "Transcription complete"
                } else {
                    self?.transcriptionStatus = "Transcription failed"
                    self?.lastTranscriptionStatus = "Transcription failed with exit code \(process.terminationStatus). Open the ASR log for details."
                    self?.lastTranscriptionDidFail = true
                    self?.updateTranscriptionState(
                        .init(phase: .failed, message: self?.lastTranscriptionStatus ?? "Transcription failed", startedAt: self?.transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
                        for: session
                    )
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
            updateTranscriptionState(
                .init(phase: .failed, message: statusMessage, startedAt: transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
                for: session
            )
        }
    }

    func cancelTranscription() {
        guard let process = transcriptionProcess, let sessionID = transcribingSessionID,
              let session = sessions.first(where: { $0.id == sessionID }) else { return }
        transcriptionCancellationRequested = true
        process.terminate()
        transcriptionStatus = "Cancelling transcription..."
        lastTranscriptionStatus = transcriptionStatus
        updateTranscriptionState(
            .init(phase: .cancelled, message: transcriptionStatus, startedAt: transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
            for: session
        )
    }

    func prepareASRModelIfNeeded() {
        refreshASRModelStatus()
        guard !asrModelReady else { return }
        guard !isPreparingASRModel else { return }

        let scriptURL = Bundle.main.resourceURL?.appendingPathComponent("prepare-qwen-asr.sh")
            ?? URL(fileURLWithPath: "/Users/apple/Documents/recorder/scripts/prepare-qwen-asr.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            asrModelStatus = "Missing ASR model preparation script: \(scriptURL.path)"
            return
        }

        isPreparingASRModel = true
        asrModelStatus = "Checking oMLX ASR server in the background..."
        statusMessage = "Checking oMLX ASR server"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        asrPrepareProcess = process

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.handleASRModelOutput(text)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.asrPrepareProcess = nil
                self?.isPreparingASRModel = false
                if process.terminationStatus == 0 {
                    self?.asrModelReady = true
                    self?.asrModelStatus = "oMLX ASR server ready"
                    self?.statusMessage = "oMLX ASR server ready"
                } else {
                    self?.asrModelReady = false
                    self?.asrModelStatus = "oMLX ASR server check failed with exit code \(process.terminationStatus)"
                    self?.statusMessage = "oMLX ASR server check failed. Open the ASR log for details."
                }
            }
        }

        do {
            try process.run()
        } catch {
            isPreparingASRModel = false
            asrPrepareProcess = nil
            asrModelStatus = "oMLX ASR server check failed: \(error.localizedDescription)"
        }
    }

    func openASRModelLog() {
        if let asrModelLogURL {
            NSWorkspace.shared.open(asrModelLogURL)
            return
        }

        let expected = URL(fileURLWithPath: "/Users/apple/Documents/AIA ASR/qwen_asr_model_prepare.log")
        if FileManager.default.fileExists(atPath: expected.path) {
            asrModelLogURL = expected
            NSWorkspace.shared.open(expected)
        } else {
            statusMessage = "No oMLX ASR server log found."
        }
    }

    func openTranscript(for session: RecordingSession) {
        if let url = transcriptURLsBySessionID[session.id] {
            NSWorkspace.shared.open(url)
            return
        }

        let expected = TranscriptDocumentStore.editableURL(in: session.folderURL)
        if FileManager.default.fileExists(atPath: expected.path) {
            transcriptURLsBySessionID[session.id] = expected
            NSWorkspace.shared.open(expected)
        } else {
            let qwenTranscript = TranscriptDocumentStore.qwenURL(in: session.folderURL)
            if FileManager.default.fileExists(atPath: qwenTranscript.path) {
                transcriptURLsBySessionID[session.id] = qwenTranscript
                NSWorkspace.shared.open(qwenTranscript)
            } else {
                statusMessage = "No transcript found for \(session.displayName)"
            }
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

    func transcriptText(for session: RecordingSession) -> String {
        do {
            return try TranscriptDocumentStore.read(in: session.folderURL)
        } catch {
            statusMessage = "Cannot read transcript: \(error.localizedDescription)"
            return ""
        }
    }

    func saveTranscript(_ text: String, for session: RecordingSession) {
        do {
            try TranscriptDocumentStore.save(text, in: session.folderURL)
            transcriptURLsBySessionID[session.id] = TranscriptDocumentStore.editableURL(in: session.folderURL)
            statusMessage = "Transcript saved"
        } catch {
            statusMessage = "Cannot save transcript: \(error.localizedDescription)"
        }
    }

    func exportTranscript(for session: RecordingSession) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.displayName).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcriptText(for: session).write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Transcript exported: \(url.lastPathComponent)"
        } catch {
            statusMessage = "Cannot export transcript: \(error.localizedDescription)"
        }
    }

    func copyTranscript(for session: RecordingSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText(for: session), forType: .string)
        statusMessage = "Transcript copied"
    }

    func saveMetadata(title: String, tags: String, isFavorite: Bool, for session: RecordingSession) {
        do {
            let metadata = RecordingSessionMetadata(
                title: title,
                tags: tags.split(separator: ",").map(String.init),
                isFavorite: isFavorite
            )
            try RecordingSessionMetadataStore.save(metadata, in: session.folderURL)
            refreshSessions()
            statusMessage = "Recording details saved"
        } catch {
            statusMessage = "Cannot save recording details: \(error.localizedDescription)"
        }
    }

    func moveSessionToTrash(_ session: RecordingSession) {
        do {
            _ = try RecordingSessionStore.moveToTrash(folder: session.folderURL)
            if playingSessionID == session.id { stopPlayback() }
            refreshSessions()
            statusMessage = "Moved \(session.displayName) to Trash"
        } catch {
            statusMessage = "Cannot move recording to Trash: \(error.localizedDescription)"
        }
    }

    private func finishRecording(playAfterStop: Bool) async {
        guard let result = await recorder.stop() else {
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

        for line in lines where line.hasPrefix("STATUS=") {
            let message = String(line.dropFirst("STATUS=".count))
            transcriptionStatus = message
            lastTranscriptionStatus = message
            let phase: TranscriptionState.Phase = message.localizedCaseInsensitiveContains("upload") ? .uploading : .transcribing
            updateTranscriptionState(
                .init(phase: phase, message: message, startedAt: transcriptionStatesBySessionID[session.id]?.startedAt ?? Date()),
                for: session
            )
        }

        for line in lines where line.hasPrefix("LOG_PATH=") {
            let path = String(line.dropFirst("LOG_PATH=".count))
            transcriptLogURLsBySessionID[session.id] = URL(fileURLWithPath: path)
        }
    }

    private func updateTranscriptionState(_ state: TranscriptionState, for session: RecordingSession) {
        transcriptionStatesBySessionID[session.id] = state
        try? TranscriptionStateStore.save(state, in: session.folderURL)
    }

    private func refreshASRModelStatus() {
        if !asrModelReady && !isPreparingASRModel {
            asrModelStatus = "oMLX ASR server not checked yet"
        }

        let logURL = URL(fileURLWithPath: "/Users/apple/Documents/AIA ASR/qwen_asr_model_prepare.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            asrModelLogURL = logURL
        }
    }

    private func handleASRModelOutput(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if let lastUsefulLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            asrModelStatus = friendlyASRModelStatus(for: lastUsefulLine)
        }

        for line in lines where line.hasPrefix("LOG_PATH=") {
            let path = String(line.dropFirst("LOG_PATH=".count))
            asrModelLogURL = URL(fileURLWithPath: path)
        }

        for line in lines where line.hasPrefix("MODEL_READY=") {
            asrModelReady = true
            asrModelStatus = "oMLX ASR server ready"
        }
    }

    private func friendlyASRModelStatus(for line: String) -> String {
        if line.contains("Checking oMLX ASR server") {
            return "Checking oMLX ASR server..."
        }
        if line.contains("Waiting for oMLX ASR model") {
            return "Waiting for oMLX ASR model..."
        }
        if line.hasPrefix("LOG_PATH=") {
            return isPreparingASRModel ? "Checking oMLX ASR server in the background..." : asrModelStatus
        }
        return line
    }

    private func requestMicrophonePermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        permissionMessage = granted ? "" : "Microphone permission is required in System Settings."
        refreshRoutingChecks()
    }
}
