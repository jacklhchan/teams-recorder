import XCTest
@testable import RecorderApp

final class TranscriptionProtocolLineDecoderTests: XCTestCase {
    func testReassemblesLinesAcrossArbitraryByteChunks() {
        var decoder = TranscriptionProtocolLineDecoder()
        XCTAssertEqual(decoder.append(Data("STA".utf8)), [])
        XCTAssertEqual(
            decoder.append(Data("TUS=Uploading\nTRANS".utf8)),
            ["STATUS=Uploading"]
        )
        XCTAssertEqual(
            decoder.append(Data("CRIPT_PATH=/tmp/a.txt\n".utf8)),
            ["TRANSCRIPT_PATH=/tmp/a.txt"]
        )
        XCTAssertEqual(decoder.finish(), [])
    }

    func testPreservesUTF8ScalarSplitAcrossChunks() {
        var decoder = TranscriptionProtocolLineDecoder()
        let bytes = Data("STATUS=上載中\n".utf8)
        let split = bytes.index(bytes.startIndex, offsetBy: 9)

        XCTAssertEqual(decoder.append(bytes[..<split]), [])
        XCTAssertEqual(decoder.append(bytes[split...]), ["STATUS=上載中"])
    }

    func testFinishPublishesFinalUnterminatedLineOnce() {
        var decoder = TranscriptionProtocolLineDecoder()
        _ = decoder.append(Data("LOG_PATH=/tmp/log".utf8))
        XCTAssertEqual(decoder.finish(), ["LOG_PATH=/tmp/log"])
        XCTAssertEqual(decoder.finish(), [])
    }
}
