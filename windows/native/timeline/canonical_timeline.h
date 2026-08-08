#pragma once

#include <cstdint>
#include <cstddef>
#include <deque>
#include <vector>

namespace recorder::timeline {

// Every mixed source is placed on one 48 kHz timeline.  qpc_100ns is the
// WASAPI packet timestamp; device_position_frames is used as an independent
// duration estimate.  The mapper never moves an already emitted packet back
// in time and bounds clock correction to 10 ms per packet.
enum class Source : std::uint8_t { Render, Microphone, Process };

struct Placement {
    std::uint64_t frame = 0;
    std::uint64_t silence_before_frames = 0;
    std::uint64_t late_frames_dropped = 0;
};

struct SourceCounters {
    std::uint64_t drift_corrections = 0;
    std::uint64_t late_packets = 0;
    std::uint64_t late_frames_dropped = 0;
    std::uint64_t discontinuities = 0;
    std::uint64_t queue_overflows = 0;
    std::uint64_t source_disconnects = 0;
};

// Shared by the capture session and deterministic CTests. Chunks retain their
// canonical start frame so missing intervals are mixed as zero rather than
// being compressed by a FIFO pull.
struct AudioChunk {
    std::vector<float> samples;
    std::uint64_t start_frame = 0;
    std::size_t offset_frames = 0;
};

void MixFrames(std::deque<AudioChunk>* queue, std::size_t* queued_frames,
               std::uint64_t output_frame, float* target,
               std::size_t output_frames);

class CanonicalTimeline final {
public:
    static constexpr std::uint32_t kSampleRate = 48'000;
    static constexpr std::uint64_t kQpcUnitsPerSecond = 10'000'000;

    void SetOrigin(std::uint64_t qpc_100ns) noexcept;
    Placement Place(Source source, std::uint64_t qpc_100ns,
                    std::uint64_t device_position_frames,
                    std::uint32_t source_sample_rate,
                    std::uint64_t normalized_frames, bool discontinuity);
    void MarkQueueOverflow(Source source) noexcept;
    void MarkDisconnected(Source source) noexcept;
    const SourceCounters& counters(Source source) const noexcept;
    // The exclusive canonical frame reached by this source.  The mixer uses
    // this watermark to wait for both inputs before committing a block: a
    // faster callback must not make the other source late by one block.
    std::uint64_t end_frame(Source source) const noexcept;
    bool has_origin() const noexcept { return has_origin_; }
    // Exposes the immutable session QPC origin for video PTS mapping.  The
    // caller must still reject frames until has_origin() is true.
    std::uint64_t origin_qpc_100ns() const noexcept { return origin_qpc_100ns_; }

private:
    struct State {
        bool initialized = false;
        std::uint64_t first_device_position = 0;
        std::uint64_t first_qpc_frame = 0;
        std::uint64_t last_end_frame = 0;
        SourceCounters counters{};
    };
    State& state(Source source) noexcept;
    const State& state(Source source) const noexcept;

    bool has_origin_ = false;
    std::uint64_t origin_qpc_100ns_ = 0;
    State render_{};
    State microphone_{};
    State process_{};
};

}  // namespace recorder::timeline
