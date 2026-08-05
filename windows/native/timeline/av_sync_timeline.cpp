#include "av_sync_timeline.h"

#include <limits>

namespace recorder::timeline {

void AvSyncTimeline::Start(std::uint64_t audio_anchor_qpc_100ns) noexcept {
    if (started_) return;
    started_ = true;
    audio_anchor_qpc_100ns_ = audio_anchor_qpc_100ns;
    audio_end_qpc_100ns_ = audio_anchor_qpc_100ns;
}

void AvSyncTimeline::AdvanceAudioEnd(std::uint64_t audio_end_qpc_100ns) noexcept {
    if (!started_) return;
    if (audio_end_qpc_100ns > audio_end_qpc_100ns_) {
        audio_end_qpc_100ns_ = audio_end_qpc_100ns;
    }
}

VideoPlacement AvSyncTimeline::PlaceVideo(std::uint64_t video_qpc_100ns,
                                          std::uint64_t duration_100ns) noexcept {
    VideoPlacement placement{};
    placement.duration_100ns = duration_100ns;
    if (!started_ || video_qpc_100ns < audio_anchor_qpc_100ns_) {
        ++counters_.dropped_before_audio_anchor;
        return placement;
    }
    if (duration_100ns == 0) {
        placement.disposition = VideoFrameDisposition::DroppedInvalidDuration;
        ++counters_.dropped_invalid_duration;
        return placement;
    }
    if (has_accepted_video_ && video_qpc_100ns <= last_video_qpc_100ns_) {
        placement.disposition = VideoFrameDisposition::DroppedDuplicateOrBackward;
        ++counters_.dropped_duplicate_or_backward;
        return placement;
    }
    const std::uint64_t latest_allowed =
        audio_end_qpc_100ns_ > std::numeric_limits<std::uint64_t>::max() - kMaximumVideoLead100ns
            ? std::numeric_limits<std::uint64_t>::max()
            : audio_end_qpc_100ns_ + kMaximumVideoLead100ns;
    if (video_qpc_100ns > latest_allowed) {
        placement.disposition = VideoFrameDisposition::DroppedTooFarAhead;
        ++counters_.dropped_too_far_ahead;
        return placement;
    }
    placement.disposition = VideoFrameDisposition::Accepted;
    placement.presentation_time_100ns = video_qpc_100ns - audio_anchor_qpc_100ns_;
    last_video_qpc_100ns_ = video_qpc_100ns;
    has_accepted_video_ = true;
    ++counters_.accepted;
    return placement;
}

}  // namespace recorder::timeline
