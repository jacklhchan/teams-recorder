#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace recorder::audio {

// Conservative repair for a single isolated full-scale sample.  It is only
// used for system loopback and leaves multi-frame transients untouched.
class ShortImpulseRepair final {
public:
    void Process(float* interleaved_stereo, std::size_t frame_count,
                 bool discontinuity) noexcept {
        if (discontinuity) {
            cooldown_frames_ = 0;
            return;
        }
        if (interleaved_stereo == nullptr || frame_count < kIsolationFrames * 2U + 3U) {
            return;
        }
        const std::size_t first = kIsolationFrames + 1U;
        const std::size_t last = frame_count - kIsolationFrames - 1U;
        for (std::size_t frame = first; frame < last; ++frame) {
            bool candidates[2] = {false, false};
            float replacements[2] = {0.0F, 0.0F};
            for (std::size_t channel = 0; channel < 2U; ++channel) {
                const auto sample = [interleaved_stereo, channel](std::size_t index) {
                    return interleaved_stereo[index * 2U + channel];
                };
                const float previous = sample(frame - 1U);
                const float current = sample(frame);
                const float next = sample(frame + 1U);
                const float replacement = (previous + next) * 0.5F;
                if (!std::isfinite(previous) || !std::isfinite(current) ||
                    !std::isfinite(next) || std::abs(current) < kMinimumMagnitude ||
                    std::abs(current - previous) < kMinimumJump ||
                    std::abs(next - current) < kMinimumJump ||
                    std::abs(current - replacement) < kMinimumResidual ||
                    std::abs(next - previous) > kMaximumEndpointSpan ||
                    !HasQuietSurroundings(interleaved_stereo, frame, channel)) {
                    continue;
                }
                candidates[channel] = true;
                replacements[channel] = replacement;
            }
            if (!candidates[0] && !candidates[1]) {
                if (cooldown_frames_ > 0) --cooldown_frames_;
                continue;
            }
            if (cooldown_frames_ > 0) {
                --cooldown_frames_;
                continue;
            }
            for (std::size_t channel = 0; channel < 2U; ++channel) {
                if (candidates[channel]) {
                    interleaved_stereo[frame * 2U + channel] = replacements[channel];
                }
            }
            cooldown_frames_ = kCooldownFrames;
        }
    }

private:
    static constexpr std::size_t kIsolationFrames = 36U;
    static constexpr std::size_t kCooldownFrames = 4U;
    static constexpr float kMinimumMagnitude = 0.65F;
    static constexpr float kMinimumJump = 0.55F;
    static constexpr float kMinimumResidual = 0.55F;
    static constexpr float kMaximumEndpointSpan = 0.10F;
    static constexpr float kMaximumSurroundingJump = 0.20F;

    static bool HasQuietSurroundings(const float* samples, std::size_t frame,
                                     std::size_t channel) noexcept {
        const auto value = [samples, channel](std::size_t index) {
            return samples[index * 2U + channel];
        };
        const std::size_t left_begin = frame - kIsolationFrames - 1U;
        for (std::size_t index = left_begin; index + 1U < frame; ++index) {
            if (!std::isfinite(value(index)) || !std::isfinite(value(index + 1U)) ||
                std::abs(value(index + 1U) - value(index)) > kMaximumSurroundingJump) {
                return false;
            }
        }
        const std::size_t right_end = frame + kIsolationFrames + 1U;
        for (std::size_t index = frame + 1U; index < right_end; ++index) {
            if (!std::isfinite(value(index)) || !std::isfinite(value(index + 1U)) ||
                std::abs(value(index + 1U) - value(index)) > kMaximumSurroundingJump) {
                return false;
            }
        }
        return true;
    }

    std::size_t cooldown_frames_ = 0;
};

}  // namespace recorder::audio
