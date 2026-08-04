#pragma once

#include <algorithm>

namespace recorder::audio {

[[nodiscard]] inline float limit_mixed_sample(const float sample) noexcept {
    return std::clamp(sample, -1.0F, 1.0F);
}

}  // namespace recorder::audio
