#pragma once

#include <cmath>
#include <cstddef>

namespace recorder::audio {

// A render-only safety margin for the observed sqrt(2) loopback peaks.  The
// helper changes amplitudes only; callers retain the original frame count,
// channel layout, and timestamps.
// Keep a small margin below unity so floating-point rounding and later mixing
// cannot turn the observed driver ceiling into another hard-clipped sample.
inline constexpr float kSystemRenderHeadroomGain = 0.70F;

[[nodiscard]] inline float ApplySystemRenderHeadroomSample(float sample) noexcept {
    // A non-finite driver sample must never reach a mixer or PCM encoder.
    return std::isfinite(sample) ? sample * kSystemRenderHeadroomGain : 0.0F;
}

inline void ApplySystemRenderHeadroom(
    float* interleaved_samples,
    std::size_t sample_count) noexcept {
    if (interleaved_samples == nullptr) {
        return;
    }
    for (std::size_t index = 0; index < sample_count; ++index) {
        interleaved_samples[index] =
            ApplySystemRenderHeadroomSample(interleaved_samples[index]);
    }
}

}  // namespace recorder::audio
