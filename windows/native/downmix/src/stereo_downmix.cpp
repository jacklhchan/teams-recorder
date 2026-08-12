#include "stereo_downmix.h"

#include <cmath>

namespace recorder::downmix {
namespace {

float FiniteOrSilence(float sample) noexcept {
    return std::isfinite(sample) ? sample : 0.0F;
}

}  // namespace

bool DownmixFrameToStereo(const float* interleaved_frame,
                          std::uint16_t source_channels,
                          float* left,
                          float* right) noexcept {
    if (interleaved_frame == nullptr || source_channels == 0 || left == nullptr || right == nullptr) {
        return false;
    }

    if (source_channels == 1) {
        const float mono = FiniteOrSilence(interleaved_frame[0]);
        *left = mono;
        *right = mono;
        return true;
    }
    if (source_channels == 2) {
        *left = FiniteOrSilence(interleaved_frame[0]);
        *right = FiniteOrSilence(interleaved_frame[1]);
        return true;
    }

    float left_sum = 0.0F;
    float right_sum = 0.0F;
    std::uint16_t left_count = 0;
    std::uint16_t right_count = 0;
    for (std::uint16_t channel = 0; channel < source_channels; ++channel) {
        if ((channel & 1U) == 0U) {
            left_sum += FiniteOrSilence(interleaved_frame[channel]);
            ++left_count;
        } else {
            right_sum += FiniteOrSilence(interleaved_frame[channel]);
            ++right_count;
        }
    }
    *left = left_sum / static_cast<float>(left_count);
    *right = right_sum / static_cast<float>(right_count);
    return true;
}

}  // namespace recorder::downmix
