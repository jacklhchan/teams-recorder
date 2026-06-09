import Foundation

struct LevelSnapshot: Equatable {
    var rms: Float = -120
    var peak: Float = -120
    var samples: [Float] = []

    var isSilent: Bool {
        rms < -55
    }

    var isClipping: Bool {
        peak > -1
    }
}

enum LevelAnalyzer {
    static func snapshot(samples channelData: UnsafePointer<Float>, frameCount: Int, waveformPoints: Int = 96) -> LevelSnapshot {
        guard frameCount > 0 else { return LevelSnapshot() }

        var sumSquares: Float = 0
        var peak: Float = 0
        let stride = max(1, frameCount / waveformPoints)
        var waveform: [Float] = []
        waveform.reserveCapacity(waveformPoints)

        var bucketPeak: Float = 0
        for index in 0..<frameCount {
            let sample = channelData[index]
            let absolute = abs(sample)
            sumSquares += sample * sample
            peak = max(peak, absolute)
            bucketPeak = max(bucketPeak, absolute)

            if index % stride == stride - 1 {
                waveform.append(bucketPeak)
                bucketPeak = 0
            }
        }

        if waveform.count < waveformPoints {
            waveform.append(bucketPeak)
        }

        let rmsLinear = sqrt(sumSquares / Float(frameCount))
        return LevelSnapshot(
            rms: decibels(from: rmsLinear),
            peak: decibels(from: peak),
            samples: waveform
        )
    }

    private static func decibels(from linear: Float) -> Float {
        guard linear > 0.000_001 else { return -120 }
        return max(-120, 20 * log10(linear))
    }
}
