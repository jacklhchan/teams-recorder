#pragma once

#include <cstdint>
#include <optional>

namespace recorder::timeline {

// Maps WGC SystemRelativeTime (QPC in 100 ns units) to the recording's shared
// session clock.  It is deliberately independent of WinRT/D3D so timestamp
// semantics remain deterministic under native unit tests.
class VideoPtsMapper final {
public:
    static constexpr std::uint64_t kQpcUnitsPerSecond = 10'000'000;
    static constexpr std::uint64_t kMaximumLeadQpc = 2 * kQpcUnitsPerSecond;

    explicit VideoPtsMapper(std::uint64_t origin_qpc_100ns) noexcept
        : origin_qpc_100ns_(origin_qpc_100ns) { }

    // Returns a session-relative video PTS only when it is strictly increasing
    // and no more than two seconds ahead of audio.  The caller must drop a
    // rejected video frame; it must never shift it forward in time.
    std::optional<std::uint64_t> Map(std::uint64_t frame_qpc_100ns,
                                     std::uint64_t audio_end_pts_100ns) noexcept;

    std::uint64_t rejected_non_monotonic() const noexcept { return rejected_non_monotonic_; }
    std::uint64_t rejected_too_far_ahead() const noexcept { return rejected_too_far_ahead_; }

private:
    std::uint64_t origin_qpc_100ns_ = 0;
    std::uint64_t last_pts_100ns_ = 0;
    bool has_last_pts_ = false;
    std::uint64_t rejected_non_monotonic_ = 0;
    std::uint64_t rejected_too_far_ahead_ = 0;
};

}  // namespace recorder::timeline
