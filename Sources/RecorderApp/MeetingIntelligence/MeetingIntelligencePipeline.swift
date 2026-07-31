import Foundation

struct MeetingIntelligenceProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case summarizingChunks
        case reducingSummaries
        case generatingFinal
    }

    let stage: Stage
    let current: Int
    let total: Int
}

protocol MeetingIntelligenceGenerating: Sendable {
    func generate(
        transcript: TranscriptDocumentSnapshot,
        snapshot: OpenAICompatibleProviderSnapshot,
        onProgress: @escaping @Sendable (MeetingIntelligenceProgress) -> Void
    ) async throws -> MeetingIntelligenceGeneratedContent
}

enum MeetingIntelligencePipelineError: LocalizedError, Equatable, Sendable {
    case sourceTooLarge
    case invalidSource
    case tooManyChunks
    case partialTooLarge
    case tooManyRequests
    case maximumDepthReached
    case deadlineExceeded
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sourceTooLarge: "The transcript is too large to summarize."
        case .invalidSource: "The transcript is empty or invalid."
        case .tooManyChunks: "The transcript requires too many summary chunks."
        case .partialTooLarge: "The provider returned an oversized partial summary."
        case .tooManyRequests: "The summary request limit was reached."
        case .maximumDepthReached: "The summary reduction limit was reached."
        case .deadlineExceeded: "The summary took too long to complete."
        case .cancelled: "Meeting intelligence was cancelled."
        }
    }
}

struct MeetingIntelligencePipeline: MeetingIntelligenceGenerating {
    typealias Now = @Sendable () -> ContinuousClock.Instant

    private enum Limits {
        static let sourceBytes = 4 * 1_024 * 1_024
        static let chunkBytes = 64 * 1_024
        static let maximumChunks = 64
        static let partialBytes = 4 * 1_024
        static let reductionFanIn = 12
        static let maximumDepth = 4
        static let maximumRequests = 71
        static let maximumDuration = Duration.seconds(1_800)
    }

    private let client: any MeetingIntelligenceRequesting
    private let now: Now

    init(
        client: any MeetingIntelligenceRequesting,
        now: @escaping Now = { ContinuousClock().now }
    ) {
        self.client = client
        self.now = now
    }

    func generate(
        transcript: TranscriptDocumentSnapshot,
        snapshot: OpenAICompatibleProviderSnapshot,
        onProgress: @escaping @Sendable (MeetingIntelligenceProgress) -> Void
    ) async throws -> MeetingIntelligenceGeneratedContent {
        let deadline = now().advanced(by: Limits.maximumDuration)
        try checkBoundary(deadline: deadline)
        guard transcript.data.count <= Limits.sourceBytes else {
            throw MeetingIntelligencePipelineError.sourceTooLarge
        }
        guard !transcript.data.isEmpty,
              let source = String(data: transcript.data, encoding: .utf8) else {
            throw MeetingIntelligencePipelineError.invalidSource
        }

        let chunks = try split(source)
        guard chunks.count <= Limits.maximumChunks else {
            throw MeetingIntelligencePipelineError.tooManyChunks
        }

        var requestCount = 0
        if chunks.count == 1 {
            try checkBoundary(deadline: deadline)
            try reserveRequest(&requestCount)
            onProgress(.init(stage: .generatingFinal, current: 1, total: 1))
            let final = try await client.requestFinalResult(input: chunks[0], snapshot: snapshot)
            try checkBoundary(deadline: deadline)
            return final
        }

        var summaries: [String] = []
        summaries.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            try checkBoundary(deadline: deadline)
            try reserveRequest(&requestCount)
            onProgress(.init(
                stage: .summarizingChunks,
                current: index + 1,
                total: chunks.count
            ))
            let summary = try await client.requestPartialSummary(input: chunk, snapshot: snapshot)
            try checkBoundary(deadline: deadline)
            try validatePartial(summary)
            summaries.append(summary)
        }

        var depth = 0
        while summaries.count > Limits.reductionFanIn || joinedByteCount(summaries) > Limits.chunkBytes {
            guard depth < Limits.maximumDepth else {
                throw MeetingIntelligencePipelineError.maximumDepthReached
            }
            let groups = stride(from: 0, to: summaries.count, by: Limits.reductionFanIn)
                .map { Array(summaries[$0 ..< min($0 + Limits.reductionFanIn, summaries.count)]) }
            var reduced: [String] = []
            reduced.reserveCapacity(groups.count)
            for (index, group) in groups.enumerated() {
                let input = group.joined(separator: "\n")
                try checkBoundary(deadline: deadline)
                try reserveRequest(&requestCount)
                onProgress(.init(
                    stage: .reducingSummaries,
                    current: index + 1,
                    total: groups.count
                ))
                let summary = try await client.requestPartialSummary(input: input, snapshot: snapshot)
                try checkBoundary(deadline: deadline)
                try validatePartial(summary)
                reduced.append(summary)
            }
            summaries = reduced
            depth += 1
        }

        let finalInput = summaries.joined(separator: "\n")
        try checkBoundary(deadline: deadline)
        try reserveRequest(&requestCount)
        onProgress(.init(stage: .generatingFinal, current: 1, total: 1))
        let final = try await client.requestFinalResult(input: finalInput, snapshot: snapshot)
        try checkBoundary(deadline: deadline)
        return final
    }

    private func reserveRequest(_ count: inout Int) throws {
        guard count < Limits.maximumRequests else {
            throw MeetingIntelligencePipelineError.tooManyRequests
        }
        count += 1
    }

    private func checkBoundary(deadline: ContinuousClock.Instant) throws {
        if Task.isCancelled {
            throw MeetingIntelligencePipelineError.cancelled
        }
        guard now() < deadline else {
            throw MeetingIntelligencePipelineError.deadlineExceeded
        }
    }

    private func validatePartial(_ summary: String) throws {
        guard !summary.isEmpty, summary.utf8.count <= Limits.partialBytes else {
            throw MeetingIntelligencePipelineError.partialTooLarge
        }
    }

    private func joinedByteCount(_ values: [String]) -> Int {
        values.reduce(max(0, values.count - 1)) { $0 + $1.utf8.count }
    }

    private func split(_ source: String) throws -> [String] {
        let data = Data(source.utf8)
        var offset = 0
        var chunks: [String] = []
        while offset < data.count {
            let upper = min(offset + Limits.chunkBytes, data.count)
            let end = preferredBoundary(in: data, start: offset, upper: upper)
            guard end > offset,
                  let chunk = String(data: data[offset ..< end], encoding: .utf8) else {
                throw MeetingIntelligencePipelineError.invalidSource
            }
            chunks.append(chunk)
            offset = end
        }
        return chunks
    }

    private func preferredBoundary(in data: Data, start: Int, upper: Int) -> Int {
        guard upper < data.count else { return upper }
        let scalarEnd = scalarBoundary(in: data, start: start, upper: upper)
        let bytes = data[start ..< scalarEnd]
        for separator in [Data("\n\n".utf8), Data("\n".utf8), Data(". ".utf8), Data("! ".utf8), Data("? ".utf8)] {
            if let range = bytes.range(of: separator, options: .backwards) {
                return start + range.upperBound
            }
        }
        return scalarEnd
    }

    private func scalarBoundary(in data: Data, start: Int, upper: Int) -> Int {
        var index = upper
        while index > start && (data[index] & 0b1100_0000) == 0b1000_0000 {
            index -= 1
        }
        return index == start ? upper : index
    }
}
