#pragma once

#include <cstdint>

namespace recorder::bridge::selected_audio {

enum class PrimarySource { SystemRender, ProcessLoopback };

// Pure routing/lifetime seam for deterministic tests. The session owns the
// actual capture objects; this helper only answers which primary source is
// intended and rejects callbacks from an earlier Start/Stop generation.
inline PrimarySource PrimaryFor(std::uint32_t target_process_id) noexcept {
    return target_process_id == 0 ? PrimarySource::SystemRender
                                  : PrimarySource::ProcessLoopback;
}

inline bool AcceptsCallback(std::uint64_t active_generation,
                            std::uint64_t callback_generation) noexcept {
    return active_generation == callback_generation;
}

}  // namespace recorder::bridge::selected_audio
