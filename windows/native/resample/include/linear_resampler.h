#pragma once

#include <cstdint>
#include <vector>

namespace recorder::resample {

enum class Error {
    Ok,
    InvalidArgument,
    InvalidState,
    Overflow,
};

/// Stateful interleaved-float streaming resampler to 48 kHz stereo.
/// Mono input is duplicated; inputs with two or more channels use channels 0 and 1.
/// Non-finite samples are converted to silence. Flush emits the terminal held sample
/// needed for ceil(inputFrames * 48000 / sourceRate) output frames, then requires Reset.
class LinearResampler final {
public:
    static constexpr std::uint32_t kOutputSampleRate = 48'000;

    LinearResampler(std::uint32_t source_sample_rate, std::uint16_t source_channels);

    Error Process(const float* interleaved_frames, std::uint64_t frame_count, std::vector<float>* output);
    Error Flush(std::vector<float>* output);
    void Reset() noexcept;

    std::uint64_t input_frames() const noexcept { return input_frames_; }
    std::uint64_t output_frames() const noexcept { return output_frames_; }

private:
    Error AppendFrame(float left, float right, std::vector<float>* output);
    std::uint64_t DesiredOutputFrames() const noexcept;

    std::uint32_t source_sample_rate_;
    std::uint16_t source_channels_;
    std::uint64_t input_frames_ = 0;
    std::uint64_t output_frames_ = 0;
    std::uint64_t next_position_numerator_ = 0;  // source-frame position * 48000
    float previous_left_ = 0.0F;
    float previous_right_ = 0.0F;
    bool has_previous_ = false;
    bool flushed_ = false;
};

}  // namespace recorder::resample
