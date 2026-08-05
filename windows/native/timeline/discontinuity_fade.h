#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace recorder::timeline {

// A rendered block cannot be retroactively crossfaded after the mixer has
// committed it.  This bounded fade-in removes the sharp zero/sample edge when
// Windows explicitly reports a source discontinuity. Callers must not infer
// one from the mixer's routine one-frame clock corrections; continuous speech
// and normal timeline alignment remain bit-exact.
constexpr std::size_t kDiscontinuityFadeFrames = 240U;  // 5 ms at 48 kHz.

enum class DiscontinuityEdge : std::uint8_t {
    None,
    SourceDiscontinuity,
};

inline void ApplyFadeInAtDiscontinuity(
    float* interleaved_stereo,
    std::size_t frame_count,
    DiscontinuityEdge edge,
    std::size_t fade_frames = kDiscontinuityFadeFrames) noexcept {
    if (interleaved_stereo == nullptr || frame_count == 0 ||
        fade_frames == 0 || edge == DiscontinuityEdge::None) {
        return;
    }

    const std::size_t applied = (std::min)(frame_count, fade_frames);
    for (std::size_t frame = 0; frame < applied; ++frame) {
        // The final faded frame is exactly unity.  Both stereo channels share
        // the gain, preserving the image and avoiding a one-channel click.
        const float gain = static_cast<float>(frame + 1U) /
            static_cast<float>(applied);
        interleaved_stereo[frame * 2U] *= gain;
        interleaved_stereo[frame * 2U + 1U] *= gain;
    }
}

inline void ApplyCrossfadeAtDiscontinuity(
    float* interleaved_stereo,
    std::size_t frame_count,
    DiscontinuityEdge edge,
    float previous_left,
    float previous_right,
    bool has_continuous_previous,
    std::size_t fade_frames = kDiscontinuityFadeFrames) noexcept {
    if (!has_continuous_previous) {
        ApplyFadeInAtDiscontinuity(
            interleaved_stereo, frame_count, edge, fade_frames);
        return;
    }
    if (interleaved_stereo == nullptr || frame_count == 0 || fade_frames == 0 ||
        edge == DiscontinuityEdge::None || !std::isfinite(previous_left) ||
        !std::isfinite(previous_right)) {
        return;
    }

    const std::size_t applied = (std::min)(frame_count, fade_frames);
    for (std::size_t frame = 0; frame < applied; ++frame) {
        const float gain = static_cast<float>(frame + 1U) /
            static_cast<float>(applied);
        const float previous_gain = 1.0F - gain;
        interleaved_stereo[frame * 2U] =
            previous_left * previous_gain + interleaved_stereo[frame * 2U] * gain;
        interleaved_stereo[frame * 2U + 1U] =
            previous_right * previous_gain + interleaved_stereo[frame * 2U + 1U] * gain;
    }
}

}  // namespace recorder::timeline
