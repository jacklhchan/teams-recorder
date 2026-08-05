#include "canonical_timeline.h"

#include <algorithm>
#include <limits>

namespace recorder::timeline {
namespace {
constexpr std::uint64_t kMaxCorrectionFrames = 480;  // 10 ms.

std::uint64_t Scale(std::uint64_t value, std::uint64_t numerator,
                    std::uint64_t denominator) {
    if (denominator == 0 || value > std::numeric_limits<std::uint64_t>::max() / numerator) {
        return 0;
    }
    return (value * numerator + denominator / 2) / denominator;
}
}  // namespace

CanonicalTimeline::State& CanonicalTimeline::state(Source source) noexcept {
    switch (source) {
    case Source::Render: return render_;
    case Source::Microphone: return microphone_;
    case Source::Process: return process_;
    }
    return render_;
}

const CanonicalTimeline::State& CanonicalTimeline::state(Source source) const noexcept {
    switch (source) {
    case Source::Render: return render_;
    case Source::Microphone: return microphone_;
    case Source::Process: return process_;
    }
    return render_;
}

void CanonicalTimeline::SetOrigin(std::uint64_t qpc_100ns) noexcept {
    if (has_origin_) return;
    has_origin_ = true;
    origin_qpc_100ns_ = qpc_100ns;
}

Placement CanonicalTimeline::Place(Source source, std::uint64_t qpc_100ns,
                                   std::uint64_t device_position_frames,
                                   std::uint32_t source_sample_rate,
                                   std::uint64_t normalized_frames,
                                   bool discontinuity,
                                   bool timestamp_reliable) {
    Placement placement{};
    State& source_state = state(source);
    if (!has_origin_) {
        SetOrigin(qpc_100ns);
    }
    if (!source_state.initialized) {
        source_state.initialized = true;
        source_state.first_device_position = device_position_frames;
        source_state.first_qpc_frame = qpc_100ns >= origin_qpc_100ns_
            ? Scale(qpc_100ns - origin_qpc_100ns_, kSampleRate, kQpcUnitsPerSecond)
            : 0;
    }
    if (discontinuity) ++source_state.counters.discontinuities;
    if (!timestamp_reliable) {
        ++source_state.counters.timestamp_errors;
        // A timestamp-error packet is valid audio with unreliable clock
        // metadata. Keep its duration continuous instead of manufacturing a
        // gap, drift correction, or dropped prefix from the bad timestamp.
        placement.frame = source_state.last_end_frame;
        if (normalized_frames <=
            std::numeric_limits<std::uint64_t>::max() - source_state.last_end_frame) {
            source_state.last_end_frame += normalized_frames;
        }
        return placement;
    }

    const std::uint64_t qpc_frame = qpc_100ns >= origin_qpc_100ns_
        ? Scale(qpc_100ns - origin_qpc_100ns_, kSampleRate, kQpcUnitsPerSecond)
        : 0;
    const std::uint64_t device_frame = source_sample_rate == 0 ||
        device_position_frames < source_state.first_device_position
        ? qpc_frame
        : source_state.first_qpc_frame + Scale(
            device_position_frames - source_state.first_device_position,
            kSampleRate, source_sample_rate);

    // QPC establishes the shared clock. Device position detects local clock
    // drift, but each correction is bounded so a bad driver cannot create a
    // large audible jump.
    std::uint64_t frame = qpc_frame;
    const std::uint64_t difference = qpc_frame > device_frame
        ? qpc_frame - device_frame : device_frame - qpc_frame;
    if (difference > kMaxCorrectionFrames) {
        ++source_state.counters.drift_corrections;
        const std::uint64_t correction = (std::min)(difference, kMaxCorrectionFrames);
        frame = device_frame > qpc_frame ? qpc_frame + correction
                                         : qpc_frame - correction;
    }

    if (frame < source_state.last_end_frame) {
        const std::uint64_t packet_end = normalized_frames >
                std::numeric_limits<std::uint64_t>::max() - frame
            ? std::numeric_limits<std::uint64_t>::max() : frame + normalized_frames;
        const std::uint64_t late = source_state.last_end_frame - frame;
        ++source_state.counters.late_packets;
        source_state.counters.late_frames_dropped += (std::min)(late, normalized_frames);
        placement.late_frames_dropped = (std::min)(late, normalized_frames);
        // A packet that arrives behind the source cursor cannot be shifted
        // into the future: that would duplicate time.  The caller removes the
        // indicated prefix (or the entire packet), and only a surviving tail
        // starts at the cursor.
        frame = source_state.last_end_frame;
        source_state.last_end_frame = (std::max)(source_state.last_end_frame, packet_end);
        placement.frame = frame;
        return placement;
    }
    placement.frame = frame;
    placement.silence_before_frames = frame > source_state.last_end_frame
        ? frame - source_state.last_end_frame : 0;
    if (normalized_frames <= std::numeric_limits<std::uint64_t>::max() - frame) {
        source_state.last_end_frame = frame + normalized_frames;
    }
    return placement;
}

void CanonicalTimeline::MarkQueueOverflow(Source source) noexcept { ++state(source).counters.queue_overflows; }
void CanonicalTimeline::MarkDisconnected(Source source) noexcept { ++state(source).counters.source_disconnects; }
const SourceCounters& CanonicalTimeline::counters(Source source) const noexcept { return state(source).counters; }
std::uint64_t CanonicalTimeline::end_frame(Source source) const noexcept {
    return state(source).last_end_frame;
}

void MixFrames(std::deque<AudioChunk>* queue, std::size_t* queued_frames,
               std::uint64_t output_frame, float* target,
               std::size_t output_frames) {
    if (queue == nullptr || queued_frames == nullptr || target == nullptr || output_frames == 0) return;
    const std::uint64_t output_end = output_frame + output_frames;
    while (!queue->empty()) {
        AudioChunk& chunk = queue->front();
        const std::size_t available = chunk.samples.size() / 2U - chunk.offset_frames;
        const std::uint64_t chunk_frame = chunk.start_frame + chunk.offset_frames;
        if (chunk_frame >= output_end) break;
        if (chunk_frame + available <= output_frame) {
            *queued_frames -= available;
            queue->pop_front();
            continue;
        }
        const std::size_t skip = chunk_frame < output_frame
            ? static_cast<std::size_t>(output_frame - chunk_frame) : 0;
        const std::uint64_t mix_frame = chunk_frame + skip;
        const std::size_t count = static_cast<std::size_t>((std::min)(
            static_cast<std::uint64_t>(available - skip), output_end - mix_frame));
        const std::size_t target_offset = static_cast<std::size_t>(mix_frame - output_frame);
        for (std::size_t sample = 0; sample < count * 2U; ++sample) {
            target[target_offset * 2U + sample] += chunk.samples[(chunk.offset_frames + skip) * 2U + sample];
        }
        const std::size_t consumed = skip + count;
        chunk.offset_frames += consumed;
        *queued_frames -= consumed;
        if (chunk.offset_frames == chunk.samples.size() / 2U) queue->pop_front();
    }
}

}  // namespace recorder::timeline
