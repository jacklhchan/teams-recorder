#pragma once

#include <cstdint>

namespace recorder::downmix {

/// Downmixes one interleaved float PCM frame to stereo.
///
/// The capture boundary does not expose a speaker channel mask, so this uses
/// channel-index rules that are stable across devices: mono is duplicated;
/// stereo is passed through exactly; and every other layout averages even
/// channel indices into left and odd indices into right. Consequently a
/// four-channel frame [0, 1, 2, 3] becomes [(0 + 2) / 2, (1 + 3) / 2].
/// Non-finite samples are treated as silence before averaging. A zero-channel
/// input is invalid and returns false without modifying the output values.
bool DownmixFrameToStereo(const float* interleaved_frame,
                          std::uint16_t source_channels,
                          float* left,
                          float* right) noexcept;

}  // namespace recorder::downmix
