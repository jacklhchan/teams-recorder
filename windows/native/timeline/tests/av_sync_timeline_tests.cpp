#include "av_sync_timeline.h"

#include <array>
#include <iostream>
#include <stdexcept>

namespace {
using recorder::timeline::AvSyncTimeline;
using recorder::timeline::VideoFrameDisposition;

void Expect(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

void TenMinutesAtThirtyFramesPerSecondKeepsSharedQpcPts() {
    AvSyncTimeline timeline;
    constexpr std::uint64_t kAnchor = 8'000'000ULL;
    constexpr std::uint64_t kVideoDuration = AvSyncTimeline::kQpcUnitsPerSecond / 30ULL;
    constexpr std::uint64_t kFrames = 18'000ULL;  // ten minutes at 30fps.
    timeline.Start(kAnchor);
    for (std::uint64_t frame = 0; frame != kFrames; ++frame) {
        const std::uint64_t qpc = kAnchor + frame * kVideoDuration;
        // Audio is intentionally observed on a different 10ms cadence. It is
        // advanced enough for the corresponding video frame, with no clock
        // conversion or accumulated rounding in the video path.
        timeline.AdvanceAudioEnd(qpc);
        const auto placement = timeline.PlaceVideo(qpc, kVideoDuration);
        Expect(placement.disposition == VideoFrameDisposition::Accepted,
               "continuous 30fps video was dropped");
        Expect(placement.presentation_time_100ns == frame * kVideoDuration,
               "video PTS drifted from its shared QPC origin");
    }
    Expect(timeline.counters().accepted == kFrames,
           "ten-minute frame count was not retained");
}

void DuplicateAndBackwardFramesAreDroppedWithoutReordering() {
    AvSyncTimeline timeline;
    timeline.Start(100U);
    timeline.AdvanceAudioEnd(10'000U);
    Expect(timeline.PlaceVideo(1'000U, 333U).disposition == VideoFrameDisposition::Accepted,
           "initial video frame was rejected");
    Expect(timeline.PlaceVideo(1'000U, 333U).disposition == VideoFrameDisposition::DroppedDuplicateOrBackward,
           "duplicate video timestamp was accepted");
    Expect(timeline.PlaceVideo(999U, 333U).disposition == VideoFrameDisposition::DroppedDuplicateOrBackward,
           "backward video timestamp was accepted");
    const auto next = timeline.PlaceVideo(1'001U, 333U);
    Expect(next.disposition == VideoFrameDisposition::Accepted && next.presentation_time_100ns == 901U,
           "a later video frame did not remain monotonic after drops");
    Expect(timeline.counters().dropped_duplicate_or_backward == 2U,
           "duplicate/backward counter is incorrect");
}

void FramesBeforeAudioAnchorAndInvalidFramesFailClosed() {
    AvSyncTimeline timeline;
    Expect(timeline.PlaceVideo(10U, 1U).disposition == VideoFrameDisposition::DroppedBeforeAudioAnchor,
           "video before audio startup was accepted");
    timeline.Start(1'000U);
    Expect(timeline.PlaceVideo(999U, 1U).disposition == VideoFrameDisposition::DroppedBeforeAudioAnchor,
           "video before the audio anchor was accepted");
    timeline.AdvanceAudioEnd(1'000U);
    Expect(timeline.PlaceVideo(1'000U, 0U).disposition == VideoFrameDisposition::DroppedInvalidDuration,
           "zero-duration video was accepted");
    Expect(timeline.counters().dropped_before_audio_anchor == 2U &&
               timeline.counters().dropped_invalid_duration == 1U,
           "pre-anchor or invalid-frame counters are incorrect");
}

void VideoMoreThanTwoSecondsAheadIsDroppedButBoundaryIsAccepted() {
    AvSyncTimeline timeline;
    timeline.Start(0U);
    timeline.AdvanceAudioEnd(5'000'000U);
    const std::uint64_t boundary = 5'000'000U + AvSyncTimeline::kMaximumVideoLead100ns;
    Expect(timeline.PlaceVideo(boundary, 333'333U).disposition == VideoFrameDisposition::Accepted,
           "video at the permitted two-second lead was dropped");
    Expect(timeline.PlaceVideo(boundary + 1U, 333'333U).disposition == VideoFrameDisposition::DroppedTooFarAhead,
           "video beyond the permitted lead was accepted");
    Expect(timeline.counters().dropped_too_far_ahead == 1U,
           "ahead-of-audio counter is incorrect");
}

}  // namespace

int main() {
    const std::array<void (*)(), 4> tests = {
        TenMinutesAtThirtyFramesPerSecondKeepsSharedQpcPts,
        DuplicateAndBackwardFramesAreDroppedWithoutReordering,
        FramesBeforeAudioAnchorAndInvalidFramesFailClosed,
        VideoMoreThanTwoSecondsAheadIsDroppedButBoundaryIsAccepted,
    };
    try {
        for (const auto test : tests) test();
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
    std::cout << "PASS av sync timeline\n";
    return 0;
}
