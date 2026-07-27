import CoreGraphics
import CoreVideo

enum VideoFrameSurfaceFormat {
    case nv12
    case bgra
}

enum VideoFrameSurfaceError: Error, Equatable {
    case invalidNV12Dimensions(width: Int, height: Int)
    case pixelBufferCreationFailed(CVReturn)
    case pixelBufferLockFailed(CVReturn)
    case missingBaseAddress(plane: Int?)
}

struct VideoFrameSurface {
    static let width = 1_600
    static let height = 900

    let pixelBuffer: CVPixelBuffer
    let format: VideoFrameSurfaceFormat

    static func makeBlack(format: VideoFrameSurfaceFormat) throws -> VideoFrameSurface {
        let pixelFormat: OSType
        switch format {
        case .nv12:
            guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
                throw VideoFrameSurfaceError.invalidNV12Dimensions(width: width, height: height)
            }
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .bgra:
            pixelFormat = kCVPixelFormatType_32BGRA
        }

        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attributes, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw VideoFrameSurfaceError.pixelBufferCreationFailed(status)
        }
        let surface = VideoFrameSurface(pixelBuffer: pixelBuffer, format: format)
        try surface.fillBlack()
        return surface
    }

    static func aspectFit(sourceWidth: CGFloat, sourceHeight: CGFloat) -> CGRect {
        guard sourceWidth > 0, sourceHeight > 0 else { return .zero }
        let scale = min(CGFloat(width) / sourceWidth, CGFloat(height) / sourceHeight)
        let fittedSize = CGSize(width: sourceWidth * scale, height: sourceHeight * scale)
        return CGRect(
            x: (CGFloat(width) - fittedSize.width) / 2,
            y: (CGFloat(height) - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func fillBlack() throws {
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw VideoFrameSurfaceError.pixelBufferLockFailed(lockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        switch format {
        case .nv12:
            try fillPlane(0, byte: 16)
            try fillPlane(1, byte: 128)
        case .bgra:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                throw VideoFrameSurfaceError.missingBaseAddress(plane: nil)
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for row in 0..<CVPixelBufferGetHeight(pixelBuffer) {
                let rowBase = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for byte in stride(from: 0, to: bytesPerRow, by: 4) {
                    rowBase[byte] = 0
                    rowBase[byte + 1] = 0
                    rowBase[byte + 2] = 0
                    rowBase[byte + 3] = 255
                }
            }
        }
    }

    private func fillPlane(_ plane: Int, byte: UInt8) throws {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
            throw VideoFrameSurfaceError.missingBaseAddress(plane: plane)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        for row in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) {
            memset(base.advanced(by: row * bytesPerRow), Int32(byte), bytesPerRow)
        }
    }
}
