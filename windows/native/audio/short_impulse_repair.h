#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace recorder::audio {

struct ShortImpulseRepairStats {
    std::uint64_t candidate_frames = 0;
    std::uint64_t repaired_frames = 0;
    std::uint64_t repaired_samples = 0;
    std::uint64_t skipped_discontinuity_packets = 0;
    std::uint64_t skipped_cooldown_frames = 0;
    float maximum_residual = 0.0F;
};

// Repairs only a single-frame, isolated impulse in canonical 48 kHz stereo
// audio. This intentionally ignores multi-frame events: Teams speech and
// notification sounds contain legitimate short, high-energy transients that
// cannot safely be distinguished by amplitude alone.
class ShortImpulseRepair final {
public:
    void Reset() noexcept {
        cooldown_frames_ = 0;
        stats_ = {};
    }

    void Process(
        float* interleaved_stereo,
        std::size_t frame_count,
        bool discontinuity) noexcept {
        if (discontinuity) {
            ++stats_.skipped_discontinuity_packets;
            cooldown_frames_ = 0;
            return;
        }
        if (interleaved_stereo == nullptr ||
            frame_count < kIsolationFrames * 2U + 3U) {
            return;
        }

        const std::size_t first = kIsolationFrames + 1U;
        const std::size_t last = frame_count - kIsolationFrames - 1U;
        for (std::size_t frame = first; frame < last; ++frame) {
            bool candidates[2] = {false, false};
            float replacements[2] = {0.0F, 0.0F};
            float frame_maximum_residual = 0.0F;
            for (std::size_t channel = 0; channel < 2U; ++channel) {
                const auto sample = [interleaved_stereo, channel](std::size_t index) {
                    return interleaved_stereo[index * 2U + channel];
                };
                const float previous = sample(frame - 1U);
                const float current = sample(frame);
                const float next = sample(frame + 1U);
                if (!std::isfinite(previous) || !std::isfinite(current) ||
                    !std::isfinite(next)) {
                    continue;
                }

                const float replacement = (previous + next) * 0.5F;
                const float residual = std::abs(current - replacement);
                frame_maximum_residual = (std::max)(frame_maximum_residual, residual);
                if (std::abs(current) < kMinimumMagnitude ||
                    std::abs(current - previous) < kMinimumJump ||
                    std::abs(next - current) < kMinimumJump ||
                    residual < kMinimumResidual ||
                    std::abs(next - previous) > kMaximumEndpointSpan ||
                    !HasQuietSurroundings(interleaved_stereo, frame, channel)) {
                    continue;
                }
                candidates[channel] = true;
                replacements[channel] = replacement;
            }

            stats_.maximum_residual =
                (std::max)(stats_.maximum_residual, frame_maximum_residual);
            const bool has_candidate = candidates[0] || candidates[1];
            if (!has_candidate) {
                if (cooldown_frames_ > 0) {
                    --cooldown_frames_;
                }
                continue;
            }

            ++stats_.candidate_frames;
            if (cooldown_frames_ > 0) {
                ++stats_.skipped_cooldown_frames;
                --cooldown_frames_;
                continue;
            }
            for (std::size_t channel = 0; channel < 2U; ++channel) {
                if (!candidates[channel]) {
                    continue;
                }
                interleaved_stereo[frame * 2U + channel] = replacements[channel];
                ++stats_.repaired_samples;
            }
            ++stats_.repaired_frames;
            cooldown_frames_ = kCooldownFrames;
        }
    }

    [[nodiscard]] const ShortImpulseRepairStats& stats() const noexcept {
        return stats_;
    }

private:
    static constexpr std::size_t kIsolationFrames = 36U;  // 0.75 ms at 48 kHz.
    static constexpr std::size_t kCooldownFrames = 4U;
    static constexpr float kMinimumMagnitude = 0.65F;
    static constexpr float kMinimumJump = 0.55F;
    static constexpr float kMinimumResidual = 0.55F;
    static constexpr float kMaximumEndpointSpan = 0.10F;
    static constexpr float kMaximumSurroundingJump = 0.20F;

    static bool HasQuietSurroundings(
        const float* samples,
        std::size_t frame,
        std::size_t channel) noexcept {
        const auto value = [samples, channel](std::size_t index) {
            return samples[index * 2U + channel];
        };
        const std::size_t left_begin = frame - kIsolationFrames - 1U;
        for (std::size_t index = left_begin; index + 1U < frame; ++index) {
            const float first = value(index);
            const float second = value(index + 1U);
            if (!std::isfinite(first) || !std::isfinite(second) ||
                std::abs(second - first) > kMaximumSurroundingJump) {
                return false;
            }
        }
        const std::size_t right_end = frame + kIsolationFrames + 1U;
        for (std::size_t index = frame + 1U; index < right_end; ++index) {
            const float first = value(index);
            const float second = value(index + 1U);
            if (!std::isfinite(first) || !std::isfinite(second) ||
                std::abs(second - first) > kMaximumSurroundingJump) {
                return false;
            }
        }
        return true;
    }

    std::size_t cooldown_frames_ = 0;
    ShortImpulseRepairStats stats_{};
};

}  // namespace recorder::audio
