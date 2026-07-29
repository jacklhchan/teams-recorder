import Foundation

struct TranscriptionProtocolLineDecoder {
    private var pending = Data()
    private var finished = false

    mutating func append<S: DataProtocol>(_ chunk: S) -> [String] {
        guard !finished else { return [] }
        pending.append(contentsOf: chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var bytes = Data(pending[..<newline])
            if bytes.last == 0x0D {
                bytes.removeLast()
            }
            lines.append(String(decoding: bytes, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    mutating func finish() -> [String] {
        guard !finished else { return [] }
        finished = true
        guard !pending.isEmpty else { return [] }
        defer { pending.removeAll(keepingCapacity: false) }
        return [String(decoding: pending, as: UTF8.self)]
    }
}
