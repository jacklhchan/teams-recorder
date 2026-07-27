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
