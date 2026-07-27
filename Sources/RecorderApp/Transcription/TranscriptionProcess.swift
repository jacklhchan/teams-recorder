import Foundation

struct TranscriptionProcessRequest: Equatable, Sendable {
    let scriptURL: URL
    let audioURL: URL
    let folderURL: URL
}

struct TranscriptionProcessResult: Equatable, Sendable {
    let exitStatus: Int32
    let output: String
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
    private let onOutput: @Sendable (String) -> Void
    private var outputData = Data()
    private var result: TranscriptionProcessResult?
    private var exitContinuation: CheckedContinuation<TranscriptionProcessResult, Never>?
    private var didTerminate = false

    init(
        request: TranscriptionProcessRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) {
        self.onOutput = onOutput
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [request.scriptURL.path, request.audioURL.path, request.folderURL.path]
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
    }

    func run() throws {
        try process.run()
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
            process.terminate()
        }
    }

    private func finish(exitStatus: Int32) {
        pipe.fileHandleForReading.readabilityHandler = nil
        consumeAvailableData(from: pipe.fileHandleForReading, readToEnd: true)

        let completion: (
            TranscriptionProcessResult,
            CheckedContinuation<TranscriptionProcessResult, Never>?
        ) = lock.withLock {
            let result = TranscriptionProcessResult(
                exitStatus: exitStatus,
                output: String(decoding: outputData, as: UTF8.self)
            )
            self.result = result
            let continuation = exitContinuation
            exitContinuation = nil
            return (result, continuation)
        }
        completion.1?.resume(returning: completion.0)
    }

    private func consumeAvailableData(from handle: FileHandle, readToEnd: Bool = false) {
        let data: Data = lock.withLock {
            let data = readToEnd ? handle.readDataToEndOfFile() : handle.availableData
            if !data.isEmpty {
                outputData.append(data)
            }
            return data
        }
        guard !data.isEmpty else { return }
        onOutput(String(decoding: data, as: UTF8.self))
    }
}
