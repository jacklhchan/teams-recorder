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
    case requestTooLarge
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
        case .requestTooLarge: "The transcript cannot fit in a meeting intelligence request."
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
    private let sizer: any MeetingIntelligenceRequestSizing
    private let now: Now

    init(
        client: any MeetingIntelligenceRequesting,
        sizer: any MeetingIntelligenceRequestSizing = OpenAICompatibleMeetingIntelligenceRequestSizer(),
        now: @escaping Now = { ContinuousClock().now }
    ) {
        self.client = client
        self.sizer = sizer
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

        let chunks = try split(source, snapshot: snapshot)
        guard chunks.count <= Limits.maximumChunks else {
            throw MeetingIntelligencePipelineError.tooManyChunks
        }

        var requestCount = 0
        if chunks.count == 1 {
            try prepareRequest(
                &requestCount,
                deadline: deadline,
                progress: .init(stage: .generatingFinal, current: 1, total: 1),
                onProgress: onProgress
            )
            let final = try await client.requestFinalResult(input: chunks[0], snapshot: snapshot)
            try checkBoundary(deadline: deadline)
            return final
        }

        var summaries: [String] = []
        summaries.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            try prepareRequest(
                &requestCount,
                deadline: deadline,
                progress: .init(
                    stage: .summarizingChunks,
                    current: index + 1,
                    total: chunks.count
                ),
                onProgress: onProgress
            )
            let summary = try await client.requestPartialSummary(input: chunk, snapshot: snapshot)
            try checkBoundary(deadline: deadline)
            try validatePartial(summary)
            summaries.append(summary)
        }

        var depth = 0
        while requiresReduction(summaries, snapshot: snapshot) {
            guard depth < Limits.maximumDepth else {
                throw MeetingIntelligencePipelineError.maximumDepthReached
            }
            let groups = try reductionGroups(summaries, snapshot: snapshot)
            var reduced: [String] = []
            reduced.reserveCapacity(groups.count)
            for (index, group) in groups.enumerated() {
                let input = group.joined(separator: "\n")
                try prepareRequest(
                    &requestCount,
                    deadline: deadline,
                    progress: .init(
                        stage: .reducingSummaries,
                        current: index + 1,
                        total: groups.count
                    ),
                    onProgress: onProgress
                )
                let summary = try await client.requestPartialSummary(input: input, snapshot: snapshot)
                try checkBoundary(deadline: deadline)
                try validatePartial(summary)
                reduced.append(summary)
            }
            summaries = reduced
            depth += 1
        }

        let finalInput = summaries.joined(separator: "\n")
        guard sizer.fits(input: finalInput, snapshot: snapshot, final: true) else {
            throw MeetingIntelligencePipelineError.requestTooLarge
        }
        try prepareRequest(
            &requestCount,
            deadline: deadline,
            progress: .init(stage: .generatingFinal, current: 1, total: 1),
            onProgress: onProgress
        )
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

    private func prepareRequest(
        _ count: inout Int,
        deadline: ContinuousClock.Instant,
        progress: MeetingIntelligenceProgress,
        onProgress: @escaping @Sendable (MeetingIntelligenceProgress) -> Void
    ) throws {
        try checkBoundary(deadline: deadline)
        try reserveRequest(&count)
        onProgress(progress)
        // A synchronous UI callback may cancel its owning task.
        try checkBoundary(deadline: deadline)
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

    private func split(
        _ source: String,
        snapshot: OpenAICompatibleProviderSnapshot
    ) throws -> [String] {
        let data = Data(source.utf8)
        var offset = 0
        var chunks: [String] = []
        while offset < data.count {
            let upper = min(offset + Limits.chunkBytes, data.count)
            let remainingSlots = Limits.maximumChunks - chunks.count - 1
            let lower = max(
                offset + 1,
                data.count - max(0, remainingSlots) * Limits.chunkBytes
            )
            let preferred = preferredBoundary(
                in: data,
                start: offset,
                lower: min(lower, upper),
                upper: upper
            )
            let end = try fittingBoundary(
                in: data,
                start: offset,
                upper: preferred,
                snapshot: snapshot,
                final: data.count <= Limits.chunkBytes
            )
            guard end > offset,
                  let chunk = String(data: data[offset ..< end], encoding: .utf8) else {
                throw MeetingIntelligencePipelineError.invalidSource
            }
            chunks.append(chunk)
            offset = end
        }
        return chunks
    }

    private func preferredBoundary(
        in data: Data,
        start: Int,
        lower: Int,
        upper: Int
    ) -> Int {
        guard upper < data.count else { return upper }
        let scalarEnd = scalarBoundary(in: data, start: start, upper: upper)
        let bytes = data[start ..< scalarEnd]
        for separator in [Data("\n\n".utf8), Data("\n".utf8), Data(". ".utf8), Data("! ".utf8), Data("? ".utf8)] {
            if let range = bytes.range(of: separator, options: .backwards),
               range.upperBound >= lower {
                return range.upperBound
            }
        }
        return scalarEnd
    }

    private func fittingBoundary(
        in data: Data,
        start: Int,
        upper: Int,
        snapshot: OpenAICompatibleProviderSnapshot,
        final: Bool
    ) throws -> Int {
        guard upper > start else { throw MeetingIntelligencePipelineError.requestTooLarge }
        let boundaries = validScalarBoundaries(in: data, start: start, upper: upper)
        guard boundaries.count > 1 else { throw MeetingIntelligencePipelineError.requestTooLarge }
        var low = 1
        var high = boundaries.count - 1
        var best: Int?
        while low <= high {
            let middle = low + (high - low) / 2
            let candidate = boundaries[middle]
            let value = String(decoding: data[start ..< candidate], as: UTF8.self)
            if sizer.fits(input: value, snapshot: snapshot, final: final) {
                best = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard let best else { throw MeetingIntelligencePipelineError.requestTooLarge }
        return best
    }

    private func validScalarBoundaries(in data: Data, start: Int, upper: Int) -> [Int] {
        var result = [start]
        guard start < upper else { return result }
        for index in (start + 1) ... upper {
            if index == data.endIndex || (data[index] & 0b1100_0000) != 0b1000_0000 {
                result.append(index)
            }
        }
        return result
    }

    private func requiresReduction(
        _ summaries: [String],
        snapshot: OpenAICompatibleProviderSnapshot
    ) -> Bool {
        summaries.count > Limits.reductionFanIn ||
            joinedByteCount(summaries) > Limits.chunkBytes ||
            !sizer.fits(input: summaries.joined(separator: "\n"), snapshot: snapshot, final: true)
    }

    private func reductionGroups(
        _ summaries: [String],
        snapshot: OpenAICompatibleProviderSnapshot
    ) throws -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        for summary in summaries {
            let candidate = current + [summary]
            if candidate.count <= Limits.reductionFanIn,
               sizer.fits(input: candidate.joined(separator: "\n"), snapshot: snapshot, final: false) {
                current = candidate
            } else {
                guard !current.isEmpty else {
                    throw MeetingIntelligencePipelineError.requestTooLarge
                }
                groups.append(current)
                guard sizer.fits(input: summary, snapshot: snapshot, final: false) else {
                    throw MeetingIntelligencePipelineError.requestTooLarge
                }
                current = [summary]
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private func scalarBoundary(in data: Data, start: Int, upper: Int) -> Int {
        var index = upper
        if index == data.endIndex { return index }
        while index > start && (data[index] & 0b1100_0000) == 0b1000_0000 {
            index -= 1
        }
        return index == start ? upper : index
    }
}
