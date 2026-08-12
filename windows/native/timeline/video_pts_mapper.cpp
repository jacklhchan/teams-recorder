#include "video_pts_mapper.h"

#include <limits>

namespace recorder::timeline {

std::optional<std::uint64_t> VideoPtsMapper::Map(
    std::uint64_t frame_qpc_100ns, std::uint64_t audio_end_pts_100ns) noexcept {
    if (frame_qpc_100ns < origin_qpc_100ns_) {
        ++rejected_non_monotonic_;
        return std::nullopt;
    }
    const std::uint64_t pts = frame_qpc_100ns - origin_qpc_100ns_;
    if (has_last_pts_ && pts <= last_pts_100ns_) {
        ++rejected_non_monotonic_;
        return std::nullopt;
    }
    const std::uint64_t maximum_pts = audio_end_pts_100ns >
            std::numeric_limits<std::uint64_t>::max() - kMaximumLeadQpc
        ? std::numeric_limits<std::uint64_t>::max()
        : audio_end_pts_100ns + kMaximumLeadQpc;
    if (pts > maximum_pts) {
        ++rejected_too_far_ahead_;
        return std::nullopt;
    }
    last_pts_100ns_ = pts;
    has_last_pts_ = true;
    return pts;
}

}  // namespace recorder::timeline
