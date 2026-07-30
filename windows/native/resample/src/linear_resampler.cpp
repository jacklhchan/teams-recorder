#include "linear_resampler.h"
#include "stereo_downmix.h"

#include <cstddef>
#include <limits>
#include <new>

namespace recorder::resample {
LinearResampler::LinearResampler(std::uint32_t source_sample_rate, std::uint16_t source_channels)
    : source_sample_rate_(source_sample_rate), source_channels_(source_channels) {}

Error LinearResampler::Process(const float* interleaved_frames, std::uint64_t frame_count, std::vector<float>* output) {
    if (output == nullptr || source_sample_rate_ == 0 || source_channels_ == 0) return Error::InvalidArgument;
    if (flushed_) return Error::InvalidState;
    if (frame_count == 0) return Error::Ok;
    constexpr auto max_input_frames = std::numeric_limits<std::uint64_t>::max() / kOutputSampleRate;
    if (interleaved_frames == nullptr) return Error::InvalidArgument;
    if (input_frames_ > max_input_frames ||
        frame_count > max_input_frames - input_frames_ ||
        frame_count > std::numeric_limits<std::size_t>::max() / source_channels_) {
        return Error::Overflow;
    }

    for (std::uint64_t offset = 0; offset != frame_count; ++offset) {
        const auto sample_offset = offset * source_channels_;
        float left = 0.0F;
        float right = 0.0F;
        if (!recorder::downmix::DownmixFrameToStereo(
                interleaved_frames + sample_offset, source_channels_, &left, &right)) {
            return Error::InvalidArgument;
        }
        if (!has_previous_) {
            previous_left_ = left;
            previous_right_ = right;
            has_previous_ = true;
            if (AppendFrame(left, right, output) != Error::Ok) return Error::Overflow;
            next_position_numerator_ = source_sample_rate_;
            ++input_frames_;
            continue;
        }

        const auto current_position = input_frames_ * kOutputSampleRate;
        const auto previous_position = current_position - kOutputSampleRate;
        while (next_position_numerator_ <= current_position) {
            const float fraction = static_cast<float>(next_position_numerator_ - previous_position) /
                static_cast<float>(kOutputSampleRate);
            const float interpolated_left = previous_left_ + (left - previous_left_) * fraction;
            const float interpolated_right = previous_right_ + (right - previous_right_) * fraction;
            if (AppendFrame(interpolated_left, interpolated_right, output) != Error::Ok) return Error::Overflow;
            if (next_position_numerator_ > std::numeric_limits<std::uint64_t>::max() - source_sample_rate_) return Error::Overflow;
            next_position_numerator_ += source_sample_rate_;
        }
        previous_left_ = left;
        previous_right_ = right;
        ++input_frames_;
    }
    return Error::Ok;
}

Error LinearResampler::Flush(std::vector<float>* output) {
    if (output == nullptr || source_sample_rate_ == 0 || source_channels_ == 0) return Error::InvalidArgument;
    if (flushed_) return Error::InvalidState;
    if (has_previous_) {
        const auto desired = DesiredOutputFrames();
        while (output_frames_ < desired) {
            if (AppendFrame(previous_left_, previous_right_, output) != Error::Ok) return Error::Overflow;
        }
    }
    flushed_ = true;
    return Error::Ok;
}

void LinearResampler::Reset() noexcept {
    input_frames_ = 0;
    output_frames_ = 0;
    next_position_numerator_ = 0;
    previous_left_ = 0.0F;
    previous_right_ = 0.0F;
    has_previous_ = false;
    flushed_ = false;
}

Error LinearResampler::AppendFrame(float left, float right, std::vector<float>* output) {
    if (output_frames_ == std::numeric_limits<std::uint64_t>::max() || output->size() > output->max_size() - 2) return Error::Overflow;
    try {
        output->reserve(output->size() + 2);
        output->push_back(left);
        output->push_back(right);
    } catch (const std::bad_alloc&) {
        return Error::Overflow;
    }
    ++output_frames_;
    return Error::Ok;
}

std::uint64_t LinearResampler::DesiredOutputFrames() const noexcept {
    const auto whole = input_frames_ / source_sample_rate_;
    const auto remainder = input_frames_ % source_sample_rate_;
    const auto remainder_output = (remainder * kOutputSampleRate + source_sample_rate_ - 1) / source_sample_rate_;
    return whole * kOutputSampleRate + remainder_output;
}

}  // namespace recorder::resample
