#include "canonical_timeline.h"

#include <array>
#include <deque>
#include <iostream>
#include <stdexcept>

namespace {
using recorder::timeline::CanonicalTimeline;
using recorder::timeline::Source;
void Expect(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }

void LongDurationHasNoTimelineCompression() {
    CanonicalTimeline timeline;
    constexpr std::uint64_t blocks = 30'000;  // ten minutes of 20 ms blocks.
    for (std::uint64_t i = 0; i != blocks; ++i) {
        const auto placement = timeline.Place(Source::Render, i * 200'000, i * 960,
                                              48'000, 960, false);
        Expect(placement.frame == i * 960, "long duration frame drifted");
    }
}

void SilenceGapsArePreserved() {
    CanonicalTimeline timeline;
    const auto first = timeline.Place(Source::Render, 0, 0, 48'000, 960, false);
    const auto after_silence = timeline.Place(Source::Render, 1'200'000, 5'760, 48'000, 960, false);
    Expect(first.frame == 0, "first packet not at zero");
    Expect(after_silence.frame == 5'760, "loopback silence was compressed");
    Expect(after_silence.silence_before_frames == 4'800, "missing silence duration wrong");
}

void MicrophoneMuteGapMapsToSilence() {
    CanonicalTimeline timeline;
    (void)timeline.Place(Source::Microphone, 0, 0, 48'000, 960, false);
    const auto resumed = timeline.Place(Source::Microphone, 800'000, 3'840, 48'000, 960, false);
    Expect(resumed.silence_before_frames == 2'880, "muted microphone gap was compressed");
}

void LateJoiningMicrophoneKeepsTheSharedClock() {
    CanonicalTimeline timeline;
    (void)timeline.Place(Source::Render, 0, 0, 48'000, 960, false);
    const auto microphone = timeline.Place(Source::Microphone, 2'000'000, 8'000, 48'000, 960, false);
    Expect(microphone.frame == 9'600, "late microphone join gained a device-clock offset");
    Expect(timeline.counters(Source::Microphone).drift_corrections == 0,
           "late microphone join was incorrectly classified as drift");
}

void MixerIntegrationRetainsGapAsSilence() {
    CanonicalTimeline timeline;
    const auto first = timeline.Place(Source::Render, 0, 0, 48'000, 960, false);
    const auto second = timeline.Place(Source::Render, 600'000, 2'880, 48'000, 960, false);
    std::deque<recorder::timeline::AudioChunk> queue;
    queue.push_back({std::vector<float>(960 * 2U, 0.25F), first.frame, 0});
    queue.push_back({std::vector<float>(960 * 2U, 0.75F), second.frame, 0});
    std::size_t queued = 1'920;
    std::vector<float> output(960 * 2U, 0.0F);
    recorder::timeline::MixFrames(&queue, &queued, 960, output.data(), 960);
    for (const float sample : output) Expect(sample == 0.0F, "production mixer compressed a silent range");
    recorder::timeline::MixFrames(&queue, &queued, 2'880, output.data(), 960);
    Expect(output[0] == 0.75F && queued == 0, "production mixer did not place resumed packet at canonical frame");
}

void DriftLateAndFaultCountersAreBounded() {
    CanonicalTimeline timeline;
    (void)timeline.Place(Source::Render, 0, 0, 48'000, 960, false);
    const auto drifted = timeline.Place(Source::Render, 200'000, 9'600, 48'000, 960, false);
    Expect(drifted.frame == 1'440, "drift correction exceeded 10ms bound");
    const auto late = timeline.Place(Source::Render, 100'000, 4'800, 48'000, 960, true);
    Expect(late.late_frames_dropped > 0, "late packet was not accounted");
    timeline.MarkQueueOverflow(Source::Render);
    timeline.MarkDisconnected(Source::Render);
    const auto& counters = timeline.counters(Source::Render);
    Expect(counters.drift_corrections >= 1 && counters.late_packets == 1 &&
               counters.discontinuities == 1 && counters.queue_overflows == 1 &&
               counters.source_disconnects == 1,
           "source counters incomplete");
}

void SourceWatermarksRequireBothInputsBeforeMixCommit() {
    CanonicalTimeline timeline;
    (void)timeline.Place(Source::Render, 0, 0, 48'000, 480, false);
    (void)timeline.Place(Source::Microphone, 0, 0, 48'000, 480, false);
    (void)timeline.Place(Source::Render, 100'000, 480, 48'000, 480, false);
    Expect(timeline.end_frame(Source::Render) == 960,
           "render watermark did not reach one mixer block");
    Expect(timeline.end_frame(Source::Microphone) == 480,
           "microphone watermark unexpectedly advanced");
    // A 20 ms mixer block cannot yet be committed: doing so would silently
    // discard the microphone's second 10 ms packet if its callback arrives
    // just after the render callback.
    Expect(timeline.end_frame(Source::Microphone) < 960,
           "late microphone packet would be lost by an early mixer commit");
    (void)timeline.Place(Source::Microphone, 100'000, 480, 48'000, 480, false);
    Expect(timeline.end_frame(Source::Microphone) == 960,
           "microphone watermark did not complete the mixer block");
}

void SelectedProcessUsesCanonicalGapsAndCounters() {
    CanonicalTimeline timeline;
    (void)timeline.Place(Source::Process, 0, 0, 48'000, 960, false);
    const auto resumed = timeline.Place(Source::Process, 600'000, 2'880, 48'000, 960, true);
    Expect(resumed.frame == 2'880 && resumed.silence_before_frames == 1'920,
           "selected-process gap was compressed");
    const auto late = timeline.Place(Source::Process, 100'000, 480, 48'000, 960, false);
    Expect(late.late_frames_dropped > 0, "selected-process late packet not dropped");
    timeline.MarkQueueOverflow(Source::Process);
    timeline.MarkDisconnected(Source::Process);
    const auto& counters = timeline.counters(Source::Process);
    Expect(counters.discontinuities == 1 && counters.late_packets == 1 &&
               counters.queue_overflows == 1 && counters.source_disconnects == 1,
           "selected-process counters incomplete");
}
}  // namespace

int main() {
    const std::array<void (*)(), 8> tests = {LongDurationHasNoTimelineCompression, SilenceGapsArePreserved,
        MicrophoneMuteGapMapsToSilence, LateJoiningMicrophoneKeepsTheSharedClock, MixerIntegrationRetainsGapAsSilence,
        SourceWatermarksRequireBothInputsBeforeMixCommit, DriftLateAndFaultCountersAreBounded,
        SelectedProcessUsesCanonicalGapsAndCounters};
    try { for (const auto test : tests) test(); }
    catch (const std::exception& error) { std::cerr << "FAIL " << error.what() << '\n'; return 1; }
    std::cout << "PASS canonical timeline\n";
    return 0;
}
