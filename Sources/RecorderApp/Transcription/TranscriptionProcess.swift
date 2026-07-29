import Foundation

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
