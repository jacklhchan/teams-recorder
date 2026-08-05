#include "window_video_publication_policy.h"
#include "av_sync_timeline.h"

int main() {
    recorder::video::AcceptedVideoRange gated;
    if (gated.CanPublish() || gated.accepted_frames() != 0 || gated.first_100ns() != 0 || gated.last_end_100ns() != 0) return 1;

    // Models the writer bootstrap: audio arrives first, then the first WGC
    // frame is later than the audio queue front. Advancing the queued tail
    // makes the frame eligible without discarding that PCM from AAC output.
    recorder::timeline::AvSyncTimeline timeline;
    timeline.Start(0);
    timeline.AdvanceAudioEnd(3'000'000U);
    const auto late_first_frame = timeline.PlaceVideo(2'500'000U, 333'333U);
    if (late_first_frame.disposition != recorder::timeline::VideoFrameDisposition::Accepted ||
        late_first_frame.presentation_time_100ns != 2'500'000U) return 1;

    // First frame is initially too far ahead of the queued tail. A later
    // audio queue update must advance the same timeline again (without
    // dequeueing PCM) and make that frame eligible for writer bootstrap.
    recorder::timeline::AvSyncTimeline delayed_bootstrap;
    delayed_bootstrap.Start(0);
    delayed_bootstrap.AdvanceAudioEnd(10'000'000U);
    if (delayed_bootstrap.PlaceVideo(35'000'000U, 333'333U).disposition !=
        recorder::timeline::VideoFrameDisposition::DroppedTooFarAhead) return 1;
    delayed_bootstrap.AdvanceAudioEnd(20'000'000U);
    if (delayed_bootstrap.PlaceVideo(35'000'000U, 333'333U).disposition !=
        recorder::timeline::VideoFrameDisposition::Accepted) return 1;

    // Audio extension has already written static samples through 5s. A fresh
    // WGC callback stamped at 4.8s must only refresh the next cadence cache;
    // it may never insert a backward 4.8s MF sample after the 5s tail.
    if (recorder::video::DecideFreshFrame(5'000'000U, 4'800'000U) !=
        recorder::video::FreshFrameAction::CacheForNextCadence ||
        recorder::video::DecideFreshFrame(5'000'000U, 5'000'000U) !=
        recorder::video::FreshFrameAction::WriteNow ||
        recorder::video::DecideFreshFrame(5'000'000U, 5'333'333U) !=
        recorder::video::FreshFrameAction::HoldLastUntilFresh) return 1;

    gated.Add(200'000U, 333'333U);
    gated.Add(533'333U, 333'333U);
    return gated.CanPublish() && gated.accepted_frames() == 2 &&
           gated.first_100ns() == 200'000U && gated.last_end_100ns() == 866'666U ? 0 : 1;
}
