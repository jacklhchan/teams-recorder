import CoreVideo
import XCTest
@testable import RecorderApp

final class VideoFrameSurfaceTests: XCTestCase {
    func testAspectFitPreservesWideAndTallSources() {
        XCTAssertEqual(VideoFrameSurface.aspectFit(sourceWidth: 3_200, sourceHeight: 900).origin.y, 225, accuracy: 0.001)
        XCTAssertEqual(VideoFrameSurface.aspectFit(sourceWidth: 3_200, sourceHeight: 900).size.width, 1_600, accuracy: 0.001)
        XCTAssertEqual(VideoFrameSurface.aspectFit(sourceWidth: 900, sourceHeight: 3_200).origin.x, 673.4375, accuracy: 0.001)
        XCTAssertEqual(VideoFrameSurface.aspectFit(sourceWidth: 900, sourceHeight: 3_200).size.height, 900, accuracy: 0.001)
    }

    func testBlackNV12AndBGRABuffersAre1600By900() throws {
        let nv12 = try VideoFrameSurface.makeBlack(format: .nv12)
        let bgra = try VideoFrameSurface.makeBlack(format: .bgra)
        XCTAssertEqual(CVPixelBufferGetWidth(nv12.pixelBuffer), 1_600)
        XCTAssertEqual(CVPixelBufferGetHeight(nv12.pixelBuffer), 900)
        XCTAssertEqual(CVPixelBufferGetWidth(bgra.pixelBuffer), 1_600)
        XCTAssertEqual(CVPixelBufferGetHeight(bgra.pixelBuffer), 900)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(nv12.pixelBuffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(bgra.pixelBuffer), kCVPixelFormatType_32BGRA)
    }

    func testNV12PlaneStrideAndFill() throws {
        let surface = try VideoFrameSurface.makeBlack(format: .nv12)
        let buffer = surface.pixelBuffer
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        for plane in 0..<2 {
            let expected: UInt8 = plane == 0 ? 16 : 128
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            for row in 0..<height {
                XCTAssertTrue(UnsafeBufferPointer(start: base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self), count: bytesPerRow).allSatisfy { $0 == expected })
            }
        }
    }

    func testBGRAAlphaAndStrideFill() throws {
        let surface = try VideoFrameSurface.makeBlack(format: .bgra)
        let buffer = surface.pixelBuffer
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            let data = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in stride(from: 0, to: bytesPerRow, by: 4) {
                XCTAssertEqual(data[column], 0)
                XCTAssertEqual(data[column + 1], 0)
                XCTAssertEqual(data[column + 2], 0)
                XCTAssertEqual(data[column + 3], 255)
            }
        }
    }
}
