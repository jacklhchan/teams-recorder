@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

struct ScreenVideoFormat: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
}

/// The pixel buffer is retained before this value leaves the SCStream callback queue.
struct ScreenVideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let sourcePTS: CMTime
    let status: SCFrameStatus
    let filterRevision: CaptureFilterRevision
}
