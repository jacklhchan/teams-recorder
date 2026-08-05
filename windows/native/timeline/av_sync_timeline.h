#pragma once

#include <cstdint>

namespace recorder::timeline {

// Pure QPC-domain placement policy for a future WGC-to-MP4 path.  It owns no
// capture or encoder objects, so all acceptance rules are deterministic.
enum class VideoFrameDisposition : std::uint8_t {
    Accepted,
    DroppedBeforeAudioAnchor,
    DroppedDuplicateOrBackward,
    DroppedInvalidDuration,
    DroppedTooFarAhead,
};

struct VideoPlacement {
    VideoFrameDisposition disposition = VideoFrameDisposition::DroppedBeforeAudioAnchor;
    std::uint64_t presentation_time_100ns = 0;
    std::uint64_t duration_100ns = 0;
};

struct AvSyncCounters {
    std::uint64_t accepted = 0;
    std::uint64_t dropped_before_audio_anchor = 0;
    std::uint64_t dropped_duplicate_or_backward = 0;
    std::uint64_t dropped_invalid_duration = 0;
    std::uint64_t dropped_too_far_ahead = 0;
};

class AvSyncTimeline final {
public:
    static constexpr std::uint64_t kQpcUnitsPerSecond = 10'000'000ULL;
    static constexpr std::uint64_t kMaximumVideoLead100ns = 2ULL * kQpcUnitsPerSecond;

    // Establishes the common audio/video QPC origin. Repeated calls preserve
    // the first origin so late callbacks cannot rewrite published PTS.
    void Start(std::uint64_t audio_anchor_qpc_100ns) noexcept;
    // Advances the known audio tail. A backward update is ignored.
    void AdvanceAudioEnd(std::uint64_t audio_end_qpc_100ns) noexcept;
    VideoPlacement PlaceVideo(std::uint64_t video_qpc_100ns,
                              std::uint64_t duration_100ns) noexcept;

    bool started() const noexcept { return started_; }
    std::uint64_t audio_anchor_qpc_100ns() const noexcept { return audio_anchor_qpc_100ns_; }
    std::uint64_t audio_end_qpc_100ns() const noexcept { return audio_end_qpc_100ns_; }
    const AvSyncCounters& counters() const noexcept { return counters_; }

private:
    bool started_ = false;
    bool has_accepted_video_ = false;
    std::uint64_t audio_anchor_qpc_100ns_ = 0;
    std::uint64_t audio_end_qpc_100ns_ = 0;
    std::uint64_t last_video_qpc_100ns_ = 0;
    AvSyncCounters counters_{};
};

}  // namespace recorder::timeline
