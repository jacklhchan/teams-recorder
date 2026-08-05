#pragma once

#include <cstdint>

namespace recorder::video {

enum class FreshFrameAction : std::uint8_t { WriteNow, HoldLastUntilFresh, CacheForNextCadence };

inline FreshFrameAction DecideFreshFrame(std::uint64_t next_written_pts_100ns,
                                         std::uint64_t fresh_pts_100ns) noexcept {
    return fresh_pts_100ns < next_written_pts_100ns
        ? FreshFrameAction::CacheForNextCadence
        : fresh_pts_100ns > next_written_pts_100ns
            ? FreshFrameAction::HoldLastUntilFresh : FreshFrameAction::WriteNow;
}

// Pure state used by the WGC/MP4 boundary. Keeping this separate lets CI prove
// that a timeline which rejects every frame cannot publish an empty MP4.
class AcceptedVideoRange final {
public:
    void Add(std::uint64_t presentation_time_100ns, std::uint64_t duration_100ns) noexcept {
        if (duration_100ns == 0) return;
        if (accepted_ == 0) first_100ns_ = presentation_time_100ns;
        ++accepted_;
        last_end_100ns_ = presentation_time_100ns + duration_100ns;
    }
    bool CanPublish() const noexcept { return accepted_ != 0; }
    std::uint64_t accepted_frames() const noexcept { return accepted_; }
    std::uint64_t first_100ns() const noexcept { return first_100ns_; }
    std::uint64_t last_end_100ns() const noexcept { return last_end_100ns_; }
private:
    std::uint64_t accepted_ = 0;
    std::uint64_t first_100ns_ = 0;
    std::uint64_t last_end_100ns_ = 0;
};

}  // namespace recorder::video
