#pragma once

#include <cstdint>
#include <vector>

namespace recorder::video {

// Scales one BGRA frame into an even-sized NV12 canvas with aspect-fit
// letterboxing.  It is a deterministic CPU fallback used by the initial WGC
// product path; callers own the source bytes and the returned frame.
bool ConvertBgraToNv12Letterboxed(const std::uint8_t* source, std::uint32_t source_stride,
                                  std::uint32_t source_width, std::uint32_t source_height,
                                  std::uint32_t target_width, std::uint32_t target_height,
                                  std::vector<std::uint8_t>* target) noexcept;

}  // namespace recorder::video
