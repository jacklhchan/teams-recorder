@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

@MainActor
final class RecordingEngine: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isMonitoring = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var outputFolder: URL?
    @Published private(set) var systemLevel = LevelSnapshot()
    @Published private(set) var micLevel = LevelSnapshot()
    @Published private(set) var micMuted = false

    private var systemEngine: AVAudioEngine?
    private var micEngine: AVAudioEngine?
    private var mixedFile: AVAudioFile?
    private var pendingSystemBuffers: [AVAudioPCMBuffer] = []
    private var pendingMicBuffers: [AVAudioPCMBuffer] = []
    private var currentRecordingURL: URL?
    private var currentHealth = RecordingHealthReport()
    private var latestSystemLevel = LevelSnapshot()
    private var latestMicLevel = LevelSnapshot()
    private var rollingSystemSamples = Array(repeating: Float(0), count: 160)
    private var rollingMicSamples = Array(repeating: Float(0), count: 160)
    private var meterTimer: Timer?

    private let processingQueue = DispatchQueue(label: "local-meeting-recorder.audio", qos: .userInitiated)
    private let sampleRate: Double = 48_000

    func startMonitoring(systemDevice: AudioDevice?, micDevice: AudioDevice?) throws {
        guard !isRecording else { return }
        stopMonitoring()
        guard let systemDevice else { throw RecordingEngineError.noSystemDevice }
        guard let micDevice else { throw RecordingEngineError.noMicDevice }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)
        guard let format else { throw RecordingEngineError.unsupportedFormat }

        let systemEngine = AVAudioEngine()
        let micEngine = AVAudioEngine()

        let systemInput = systemEngine.inputNode
        let micInput = micEngine.inputNode
        try configure(inputNode: systemInput, deviceID: systemDevice.id)
        try configure(inputNode: micInput, deviceID: micDevice.id)

        let systemInputFormat = systemInput.inputFormat(forBus: 0)
        let micInputFormat = micInput.inputFormat(forBus: 0)
        guard systemInputFormat.sampleRate > 0, micInputFormat.sampleRate > 0 else {
            throw RecordingEngineError.unsupportedFormat
        }

        installTap(node: systemInput, sourceFormat: systemInputFormat, writeFormat: format, kind: .system)
        installTap(node: micInput, sourceFormat: micInputFormat, writeFormat: format, kind: .mic)

        do {
            try systemEngine.start()
            try micEngine.start()
        } catch {
            stopMonitoring()
            throw RecordingEngineError.engineStartFailed(error.localizedDescription)
        }

        self.systemEngine = systemEngine
        self.micEngine = micEngine
        isMonitoring = true
        startMeterTimer()
    }

    func stopMonitoring() {
        guard !isRecording else { return }
        systemEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.inputNode.removeTap(onBus: 0)
        systemEngine?.stop()
        micEngine?.stop()
        systemEngine = nil
        micEngine = nil
        pendingSystemBuffers.removeAll()
        pendingMicBuffers.removeAll()
        rollingSystemSamples = Array(repeating: Float(0), count: 160)
        rollingMicSamples = Array(repeating: Float(0), count: 160)
        isMonitoring = false
        stopMeterTimer()
    }

    @discardableResult
    func start(systemDevice: AudioDevice?, micDevice: AudioDevice?, baseFolder: URL, folderPrefix: String = "meeting") throws -> URL {
        guard !isRecording else { return outputFolder ?? baseFolder }
        guard let systemDevice else { throw RecordingEngineError.noSystemDevice }
        guard let micDevice else { throw RecordingEngineError.noMicDevice }
        if !isMonitoring {
            try startMonitoring(systemDevice: systemDevice, micDevice: micDevice)
        }

        let folder = baseFolder
            .appendingPathComponent("\(folderPrefix)-\(Self.folderStamp.string(from: Date()))", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw RecordingEngineError.cannotCreateFolder
        }

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]

        let recordingURL = folder.appendingPathComponent("recording.m4a")
        mixedFile = try AVAudioFile(forWriting: recordingURL, settings: fileSettings)
        currentRecordingURL = recordingURL
        currentHealth = RecordingHealthReport(startedAt: Date())
        outputFolder = folder
        startedAt = Date()
        isRecording = true
        return folder
    }

    func stop() -> RecordingResult? {
        guard isRecording || systemEngine != nil || micEngine != nil else { return nil }

        mixedFile = nil
        currentHealth.endedAt = Date()
        let result = outputFolder.flatMap { folder in
            currentRecordingURL.map {
                RecordingResult(folderURL: folder, recordingURL: $0, health: currentHealth)
            }
        }
        pendingSystemBuffers.removeAll()
        pendingMicBuffers.removeAll()
        currentRecordingURL = nil
        startedAt = nil
        isRecording = false
        micMuted = false
        return result
    }

    func toggleMicMute() {
        micMuted.toggle()
    }

    private func installTap(node: AVAudioInputNode, sourceFormat: AVAudioFormat, writeFormat: AVAudioFormat, kind: SourceKind) {
        node.installTap(onBus: 0, bufferSize: 512, format: sourceFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.processingQueue.async {
                self.process(buffer: buffer, writeFormat: writeFormat, kind: kind)
            }
        }
    }

    nonisolated private func process(buffer: AVAudioPCMBuffer, writeFormat: AVAudioFormat, kind: SourceKind) {
        guard let converted = Self.convert(buffer: buffer, to: writeFormat),
              let firstChannel = converted.floatChannelData?.pointee else {
            return
        }

        let frameCount = Int(converted.frameLength)
        let snapshot = LevelAnalyzer.snapshot(samples: firstChannel, frameCount: frameCount)

        Task { @MainActor in
            switch kind {
            case .system:
                self.latestSystemLevel = snapshot
            case .mic:
                self.latestMicLevel = snapshot
            }
        }

        Task { @MainActor in
            guard self.isRecording else { return }
            self.updateHealth(with: snapshot, kind: kind)
            do {
                switch kind {
                case .system:
                    if let copied = Self.copy(converted) {
                        self.pendingSystemBuffers.append(copied)
                    }
                    try self.writeMixedFramesIfReady()
                case .mic:
                    if self.micMuted {
                        Self.silence(converted)
                    }
                    if let copied = Self.copy(converted) {
                        self.pendingMicBuffers.append(copied)
                    }
                    try self.writeMixedFramesIfReady()
                }
            } catch {
                NSLog("Recorder write failed: \(error.localizedDescription)")
            }
        }
    }

    private func writeMixedFramesIfReady() throws {
        while !pendingSystemBuffers.isEmpty, !pendingMicBuffers.isEmpty {
            let system = pendingSystemBuffers.removeFirst()
            let mic = pendingMicBuffers.removeFirst()
            let frameLength = min(system.frameLength, mic.frameLength)
            guard let output = AVAudioPCMBuffer(pcmFormat: system.format, frameCapacity: frameLength) else { return }
            output.frameLength = frameLength

            Self.add(system, into: output, gain: 0.48, frameLimit: frameLength)
            Self.add(mic, into: output, gain: 0.48, frameLimit: frameLength)
            Self.softLimit(output, frameLimit: frameLength)

            try mixedFile?.write(from: output)
        }

        trimPendingBuffers()
    }

    private func trimPendingBuffers() {
        let maxPendingBuffers = 20
        if pendingSystemBuffers.count > maxPendingBuffers {
            currentHealth.droppedBuffers += pendingSystemBuffers.count - maxPendingBuffers
            pendingSystemBuffers.removeFirst(pendingSystemBuffers.count - maxPendingBuffers)
        }
        if pendingMicBuffers.count > maxPendingBuffers {
            currentHealth.droppedBuffers += pendingMicBuffers.count - maxPendingBuffers
            pendingMicBuffers.removeFirst(pendingMicBuffers.count - maxPendingBuffers)
        }
    }

    private func updateHealth(with snapshot: LevelSnapshot, kind: SourceKind) {
        switch kind {
        case .system:
            currentHealth.systemSignalSeen = currentHealth.systemSignalSeen || snapshot.rms > -55
        case .mic:
            currentHealth.micSignalSeen = currentHealth.micSignalSeen || (!micMuted && snapshot.rms > -55)
        }

        if snapshot.isClipping {
            currentHealth.clippingEvents += 1
        }
    }

    private func startMeterTimer() {
        stopMeterTimer()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.rollingSystemSamples = Self.roll(self.rollingSystemSamples, next: Self.waveformSample(from: self.latestSystemLevel))
                self.rollingMicSamples = Self.roll(
                    self.rollingMicSamples,
                    next: self.micMuted ? 0 : Self.waveformSample(from: self.latestMicLevel)
                )

                self.systemLevel = LevelSnapshot(
                    rms: Self.smoothDecibels(current: self.systemLevel.rms, target: self.latestSystemLevel.rms),
                    peak: Self.smoothDecibels(current: self.systemLevel.peak, target: self.latestSystemLevel.peak),
                    samples: self.rollingSystemSamples
                )
                let displayedMicLevel = self.micMuted ? LevelSnapshot() : self.latestMicLevel
                self.micLevel = LevelSnapshot(
                    rms: Self.smoothDecibels(current: self.micLevel.rms, target: displayedMicLevel.rms),
                    peak: Self.smoothDecibels(current: self.micLevel.peak, target: displayedMicLevel.peak),
                    samples: self.rollingMicSamples
                )
            }
        }
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    nonisolated private static func waveformSample(from snapshot: LevelSnapshot) -> Float {
        if let peak = snapshot.samples.max(), peak > 0 {
            return min(1, max(0, peak))
        }

        guard snapshot.rms > -90 else { return 0 }
        return min(1, max(0, pow(10, snapshot.rms / 20)))
    }

    nonisolated private static func roll(_ samples: [Float], next sample: Float) -> [Float] {
        guard !samples.isEmpty else { return [sample] }
        return Array(samples.dropFirst()) + [sample]
    }

    nonisolated private static func smoothDecibels(current: Float, target: Float) -> Float {
        let coefficient: Float = target > current ? 0.42 : 0.16
        return current + (target - current) * coefficient
    }

    private func configure(inputNode: AVAudioInputNode, deviceID: AudioDeviceID) throws {
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw RecordingEngineError.engineStartFailed("Cannot bind input device \(deviceID), OSStatus \(status)")
        }
    }

    nonisolated private static func convert(buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        return error == nil ? output : nil
    }

    nonisolated private static func add(_ source: AVAudioPCMBuffer, into output: AVAudioPCMBuffer, gain: Float, frameLimit: AVAudioFrameCount? = nil) {
        guard let sourceData = source.floatChannelData,
              let outputData = output.floatChannelData else {
            return
        }

        let channels = min(Int(source.format.channelCount), Int(output.format.channelCount))
        let availableFrames = min(source.frameLength, output.frameLength)
        let frames = Int(min(availableFrames, frameLimit ?? availableFrames))
        for channel in 0..<channels {
            for frame in 0..<frames {
                outputData[channel][frame] += sourceData[channel][frame] * gain
            }
        }
    }

    nonisolated private static func softLimit(_ buffer: AVAudioPCMBuffer, frameLimit: AVAudioFrameCount? = nil) {
        guard let data = buffer.floatChannelData else { return }

        let frames = Int(min(buffer.frameLength, frameLimit ?? buffer.frameLength))
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<frames {
                let sample = data[channel][frame]
                data[channel][frame] = tanh(sample * 1.15) / tanh(1.15)
            }
        }
    }

    nonisolated private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            return nil
        }
        copy.frameLength = source.frameLength
        add(source, into: copy, gain: 1)
        return copy
    }

    nonisolated private static func silence(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            memset(data[channel], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }
    }

    private enum SourceKind {
        case system
        case mic
    }

    private static let folderStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}
