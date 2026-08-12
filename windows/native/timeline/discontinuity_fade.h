#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace recorder::timeline {

constexpr std::size_t kDiscontinuityFadeFrames = 240U;  // 5 ms at 48 kHz.

enum class DiscontinuityEdge : std::uint8_t { None, SourceDiscontinuity };

inline void ApplyCrossfadeAtDiscontinuity(
    float* interleaved_stereo, std::size_t frame_count, DiscontinuityEdge edge,
    float previous_left, float previous_right, bool has_continuous_previous,
    std::size_t fade_frames = kDiscontinuityFadeFrames) noexcept {
    if (interleaved_stereo == nullptr || frame_count == 0 || fade_frames == 0 ||
        edge == DiscontinuityEdge::None) return;
    const std::size_t applied = (std::min)(frame_count, fade_frames);
    if (!has_continuous_previous || !std::isfinite(previous_left) ||
        !std::isfinite(previous_right)) {
        for (std::size_t frame = 0; frame < applied; ++frame) {
            const float gain = static_cast<float>(frame + 1U) / static_cast<float>(applied);
            interleaved_stereo[frame * 2U] *= gain;
            interleaved_stereo[frame * 2U + 1U] *= gain;
        }
        return;
    }
    for (std::size_t frame = 0; frame < applied; ++frame) {
        const float gain = static_cast<float>(frame + 1U) / static_cast<float>(applied);
        const float previous_gain = 1.0F - gain;
        interleaved_stereo[frame * 2U] = previous_left * previous_gain +
            interleaved_stereo[frame * 2U] * gain;
        interleaved_stereo[frame * 2U + 1U] = previous_right * previous_gain +
            interleaved_stereo[frame * 2U + 1U] * gain;
    }
}

}  // namespace recorder::timeline
