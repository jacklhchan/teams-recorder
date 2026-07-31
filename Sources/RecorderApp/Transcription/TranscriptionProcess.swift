import Foundation

struct OpenAICompatibleTranscriptionLaunchPayload:
    Codable,
    Equatable,
    Sendable
{
    let schemaVersion: Int
    let baseURL: String
    let asrModel: String
    let language: String
    let prompt: String
    let apiKey: String?

    init(snapshot: OpenAICompatibleProviderSnapshot) {
        schemaVersion = 1
        baseURL = snapshot.profile.baseURL.absoluteString
        asrModel = snapshot.profile.asrModel
        language = snapshot.profile.language
        prompt = snapshot.profile.prompt
        apiKey = snapshot.apiKey
    }
}

struct TranscriptionProtocolSnapshot {
    var status: String?
    var transcriptPath: String?
    var logPath: String?

    init(lines: [String]) {
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !line.isEmpty else { continue }
            if line.hasPrefix("STATUS=") {
                status = String(line.dropFirst("STATUS=".count))
            } else if line.hasPrefix("TRANSCRIPT_PATH=") {
                transcriptPath = String(
                    line.dropFirst("TRANSCRIPT_PATH=".count)
                )
            } else if line.hasPrefix("LOG_PATH=") {
                logPath = String(line.dropFirst("LOG_PATH=".count))
            }
        }
    }
}

struct TranscriptionProcessRequest: Equatable, Sendable {
    let scriptURL: URL
    let audioURL: URL
    let folderURL: URL
    let configurationInput: Data
}

struct TranscriptionProcessResult: Equatable, Sendable {
    let exitStatus: Int32
    let output: String
    let protocolLines: [String]
}

protocol TranscriptionProcessing: AnyObject {
    func run() throws
    func waitForExit() async -> TranscriptionProcessResult
    func terminate()
}

protocol TranscriptionProcessLaunching {
    func makeProcess(
        request: TranscriptionProcessRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws -> any TranscriptionProcessing
}

struct FoundationTranscriptionProcessLauncher: TranscriptionProcessLaunching {
    func makeProcess(
        request: TranscriptionProcessRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws -> any TranscriptionProcessing {
        FoundationTranscriptionProcess(request: request, onOutput: onOutput)
    }
}

enum LegacyProcessTranscriptionServiceError:
    LocalizedError,
    Equatable,
    Sendable
{
    case completedWithoutTranscript
    case invalidArtifactPath
    case processFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .completedWithoutTranscript:
            "Transcription completed without a valid transcript file."
        case .invalidArtifactPath:
            "Transcription reported an invalid artifact path."
        case .processFailed(let status):
            "Transcription failed with exit code \(status). "
                + "Open the ASR log for details."
        }
    }
}

final class LegacyProcessTranscriptionService:
    TranscriptionServicing,
    @unchecked Sendable
{
    private let launcher: any TranscriptionProcessLaunching
    private let scriptURL: URL
    private let transcriptReader: any TranscriptDocumentReading
    private let lock = NSLock()
    private var activeProcess: (any TranscriptionProcessing)?

    init(
        launcher: any TranscriptionProcessLaunching,
        scriptURL: URL,
        transcriptReader: any TranscriptDocumentReading =
            SecureTranscriptDocumentReader()
    ) {
        self.launcher = launcher
        self.scriptURL = scriptURL
        self.transcriptReader = transcriptReader
    }

    func transcribe(
        _ request: TranscriptionServiceRequest,
        onProgress: @escaping @Sendable (
            TranscriptionServiceProgress
        ) -> Void
    ) async throws -> TranscriptionServiceResult {
        let configurationInput = try JSONEncoder().encode(
            OpenAICompatibleTranscriptionLaunchPayload(
                snapshot: request.snapshot
            )
        )
        let process = try launcher.makeProcess(
            request: .init(
                scriptURL: scriptURL,
                audioURL: request.audioURL,
                folderURL: request.sessionFolder,
                configurationInput: configurationInput
            ),
            onOutput: { text in
                for line in text.split(
                    whereSeparator: \.isNewline
                ).map(String.init) where line.hasPrefix("STATUS=") {
                    let message = String(
                        line.dropFirst("STATUS=".count)
                    )
                    let phase: TranscriptionState.Phase =
                        message.localizedCaseInsensitiveContains("upload")
                        ? .uploading : .transcribing
                    onProgress(
                        .status(message: message, phase: phase)
                    )
                }
            }
        )
        lock.withLock { activeProcess = process }
        defer {
            lock.withLock {
                if activeProcess === process {
                    activeProcess = nil
                }
            }
        }

        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try process.run()
            let result = await process.waitForExit()
            try Task.checkCancellation()
            guard result.exitStatus == 0 else {
                throw LegacyProcessTranscriptionServiceError
                    .processFailed(result.exitStatus)
            }
            let snapshot = TranscriptionProtocolSnapshot(
                lines: result.protocolLines
            )
            guard let transcriptPath = snapshot.transcriptPath else {
                throw LegacyProcessTranscriptionServiceError
                    .completedWithoutTranscript
            }
            guard let transcriptURL = validatedArtifact(
                path: transcriptPath,
                in: request.sessionFolder
            ) else {
                throw LegacyProcessTranscriptionServiceError
                    .invalidArtifactPath
            }
            let logURL: URL?
            if let logPath = snapshot.logPath {
                guard let validated = validatedArtifact(
                    path: logPath,
                    in: request.sessionFolder
                ) else {
                    throw LegacyProcessTranscriptionServiceError
                        .invalidArtifactPath
                }
                logURL = validated
            } else {
                logURL = nil
            }
            if let status = snapshot.status {
                onProgress(
                    .status(
                        message: status,
                        phase: .transcribing
                    )
                )
            }
            let committed = try transcriptReader.readCanonical(
                in: request.sessionFolder,
                allowLegacy: true
            )
            guard committed.url == transcriptURL else {
                throw LegacyProcessTranscriptionServiceError.invalidArtifactPath
            }
            return .init(
                transcriptURL: transcriptURL,
                rawTranscriptURL: existingCanonical(
                    named: TranscriptDocumentStore.rawFileName,
                    in: request.sessionFolder
                ),
                manifestURL: existingCanonical(
                    named: TranscriptDocumentStore.manifestFileName,
                    in: request.sessionFolder
                ),
                logURL: logURL,
                committedTranscriptRevision: committed.revision
            )
        }, onCancel: {
            process.terminate()
        })
    }

    private func validatedArtifact(
        path: String,
        in sessionFolder: URL
    ) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let expectedParent = sessionFolder
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == expectedParent,
              RecordingSessionStore.isRegularFile(candidate) else {
            return nil
        }
        return candidate
    }

    private func existingCanonical(
        named name: String,
        in folder: URL
    ) -> URL? {
        let url = folder.appendingPathComponent(name)
        return RecordingSessionStore.isRegularFile(url) ? url : nil
    }
}

private final class FoundationTranscriptionProcess: TranscriptionProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let pipe = Pipe()
    private let inputPipe = Pipe()
    private let onOutput: @Sendable (String) -> Void
    private let configurationInput: Data
    private var outputData = Data()
    private var protocolDecoder = TranscriptionProtocolLineDecoder()
    private var protocolLines: [String] = []
    private var result: TranscriptionProcessResult?
    private var exitContinuation: CheckedContinuation<TranscriptionProcessResult, Never>?
    private var didTerminate = false

    init(
        request: TranscriptionProcessRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) {
        self.onOutput = onOutput
        configurationInput = request.configurationInput
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [request.scriptURL.path, request.audioURL.path, request.folderURL.path]
        process.standardInput = inputPipe
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeAvailableData(from: handle)
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(exitStatus: process.terminationStatus)
        }
    }

    deinit {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
    }

    func run() throws {
        do {
            try process.run()
            try inputPipe.fileHandleForWriting.write(contentsOf: configurationInput)
            try inputPipe.fileHandleForWriting.close()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
            throw error
        }
    }

    func waitForExit() async -> TranscriptionProcessResult {
        await withCheckedContinuation { continuation in
            let completedResult: TranscriptionProcessResult? = lock.withLock {
                if let result {
                    return result
                }
                exitContinuation = continuation
                return nil
            }
            if let completedResult {
                continuation.resume(returning: completedResult)
            }
        }
    }

    func terminate() {
        let shouldTerminate = lock.withLock {
            guard !didTerminate else { return false }
            didTerminate = true
            return true
        }
        if shouldTerminate {
            try? inputPipe.fileHandleForWriting.close()
            process.terminate()
        }
    }

    private func finish(exitStatus: Int32) {
        pipe.fileHandleForReading.readabilityHandler = nil
        consumeAvailableData(from: pipe.fileHandleForReading, readToEnd: true)

        let completion: (
            TranscriptionProcessResult,
            CheckedContinuation<TranscriptionProcessResult, Never>?,
            [String]
        ) = lock.withLock {
            let finalLines = protocolDecoder.finish()
            protocolLines.append(contentsOf: finalLines.filter(Self.isProtocolLine))
            let result = TranscriptionProcessResult(
                exitStatus: exitStatus,
                output: String(decoding: outputData, as: UTF8.self),
                protocolLines: protocolLines
            )
            self.result = result
            let continuation = exitContinuation
            exitContinuation = nil
            return (result, continuation, finalLines)
        }
        for line in completion.2 {
            onOutput(line)
        }
        completion.1?.resume(returning: completion.0)
    }

    private func consumeAvailableData(from handle: FileHandle, readToEnd: Bool = false) {
        let lines: [String] = lock.withLock {
            let data = readToEnd ? handle.readDataToEndOfFile() : handle.availableData
            guard !data.isEmpty else { return [] }
            outputData.append(data)
            let lines = protocolDecoder.append(data)
            protocolLines.append(contentsOf: lines.filter(Self.isProtocolLine))
            return lines
        }
        for line in lines {
            onOutput(line)
        }
    }

    private static func isProtocolLine(_ line: String) -> Bool {
        line.hasPrefix("STATUS=")
            || line.hasPrefix("TRANSCRIPT_PATH=")
            || line.hasPrefix("LOG_PATH=")
            || line.hasPrefix("ERROR=")
    }
}
