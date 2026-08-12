#pragma once

#include <cmath>
#include <cstddef>

namespace recorder::audio {

// A fixed linear safety margin for the observed shared-mode loopback peaks
// above unity.  Apply before mixing, so the final limiter is a last-resort
// guard rather than a distortion source for normal system audio.
inline constexpr float kSystemRenderHeadroomGain = 0.70F;

[[nodiscard]] inline float ApplySystemRenderHeadroomSample(float sample) noexcept {
    return std::isfinite(sample) ? sample * kSystemRenderHeadroomGain : 0.0F;
}

inline void ApplySystemRenderHeadroom(float* interleaved_samples,
                                      std::size_t sample_count) noexcept {
    if (interleaved_samples == nullptr) return;
    for (std::size_t index = 0; index < sample_count; ++index) {
        interleaved_samples[index] =
            ApplySystemRenderHeadroomSample(interleaved_samples[index]);
    }
}

}  // namespace recorder::audio
