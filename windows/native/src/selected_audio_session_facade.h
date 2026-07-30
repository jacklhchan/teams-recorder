#pragma once

#include <cstdint>

namespace recorder::bridge::selected_audio {

enum class PrimarySource { SystemRender, ProcessLoopback };

// The selected/process or system source is the recording's clock and media
// authority. A microphone is explicitly optional: after a successful start,
// losing it must leave the primary capture running and represent its missing
// portion as silence on the canonical timeline instead of discarding a Teams
// recording that is already in progress.
enum class MixedSourceRole { Primary, OptionalMicrophone };

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

inline bool DisconnectFailsSession(MixedSourceRole role) noexcept {
    return role == MixedSourceRole::Primary;
}

}  // namespace recorder::bridge::selected_audio
