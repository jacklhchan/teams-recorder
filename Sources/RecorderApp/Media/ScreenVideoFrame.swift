@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

struct ScreenVideoFormat: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
}

extension ScreenCaptureStartupPixelFormat {
    var coreVideoValue: OSType {
        switch self {
        case .nv12:
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .bgra:
            kCVPixelFormatType_32BGRA
        }
    }
}

/// The pixel buffer is retained before this value leaves the SCStream callback queue.
struct ScreenVideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let sourcePTS: CMTime
    let status: SCFrameStatus
    let filterRevision: CaptureFilterRevision
}

struct ScreenVideoFrameContinuity {
    private var retainedSurface: (
        pixelBuffer: CVPixelBuffer,
        filterRevision: CaptureFilterRevision
    )?

    mutating func makeFrame(
        status: SCFrameStatus,
        pixelBuffer: CVPixelBuffer?,
        sourcePTS: CMTime,
        filterRevision: CaptureFilterRevision,
        expectedPixelFormat: OSType
    ) -> ScreenVideoFrame? {
        switch status {
        case .complete, .started:
            guard isValid(sourcePTS),
                  let pixelBuffer,
                  CVPixelBufferGetPixelFormatType(pixelBuffer) == expectedPixelFormat else {
                retainedSurface = nil
                return nil
            }
            retainedSurface = (pixelBuffer, filterRevision)
            return ScreenVideoFrame(
                pixelBuffer: pixelBuffer,
                sourcePTS: sourcePTS,
                status: .complete,
                filterRevision: filterRevision
            )
        case .idle:
            guard isValid(sourcePTS),
                  let retainedSurface,
                  retainedSurface.filterRevision == filterRevision,
                  CVPixelBufferGetPixelFormatType(retainedSurface.pixelBuffer)
                    == expectedPixelFormat else {
                return nil
            }
            return ScreenVideoFrame(
                pixelBuffer: retainedSurface.pixelBuffer,
                sourcePTS: sourcePTS,
                status: status,
                filterRevision: filterRevision
            )
        default:
            retainedSurface = nil
            return nil
        }
    }

    private func isValid(_ time: CMTime) -> Bool {
        time.isValid
            && !time.isIndefinite
            && !time.isPositiveInfinity
            && !time.isNegativeInfinity
    }
}
