#include "linear_resampler.h"

#include <array>
#include <cmath>
#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <utility>
#include <vector>

namespace {

using recorder::resample::Error;
using recorder::resample::LinearResampler;

void Expect(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

void ExpectNear(float expected, float actual) {
    if (std::fabs(expected - actual) > 0.00001F) throw std::runtime_error("sample mismatch");
}

std::vector<float> Convert(std::uint32_t rate, std::uint16_t channels, const std::vector<float>& input) {
    LinearResampler resampler(rate, channels);
    std::vector<float> output;
    const auto frame_count = static_cast<std::uint64_t>(input.size() / channels);
    Expect(resampler.Process(input.data(), frame_count, &output) == Error::Ok, "process failed");
    Expect(resampler.Flush(&output) == Error::Ok, "flush failed");
    return output;
}

void Passthrough48k() {
    const std::vector<float> input = {0.0F, 1.0F, 0.25F, -0.25F, -1.0F, 0.5F};
    const auto output = Convert(48'000, 2, input);
    Expect(output == input, "48 kHz must be exactly passthrough");
}

void MultiBlockMatchesSingleBlock() {
    std::vector<float> input;
    for (int frame = 0; frame != 137; ++frame) {
        input.push_back(static_cast<float>(frame) / 137.0F);
        input.push_back(static_cast<float>(137 - frame) / 137.0F);
    }
    const auto expected = Convert(44'100, 2, input);
    LinearResampler resampler(44'100, 2);
    std::vector<float> actual;
    const std::array<std::uint64_t, 4> blocks = {1, 16, 53, 67};
    std::uint64_t offset = 0;
    for (const auto frames : blocks) {
        Expect(resampler.Process(input.data() + offset * 2, frames, &actual) == Error::Ok, "multi-block process failed");
        offset += frames;
    }
    Expect(resampler.Flush(&actual) == Error::Ok && actual == expected, "block boundary changed output");
}

void MonoIsDuplicatedAndNonFiniteIsSilence() {
    const std::vector<float> input = {0.25F, std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity()};
    const auto output = Convert(48'000, 1, input);
    Expect(output.size() == 6, "unexpected mono output size");
    for (std::size_t frame = 0; frame != 3; ++frame) {
        ExpectNear(output[frame * 2], output[frame * 2 + 1]);
    }
    ExpectNear(0.0F, output[2]);
    ExpectNear(0.0F, output[4]);
}

void FourChannelInputIsDownmixedBeforeResampling() {
    const std::vector<float> input = {
        0.2F, 0.4F, 0.6F, -0.2F,
        -0.8F, 0.3F, 0.4F, 0.7F,
    };
    const auto output = Convert(48'000, 4, input);
    Expect(output.size() == 4, "unexpected four-channel output size");
    ExpectNear(0.4F, output[0]);
    ExpectNear(0.1F, output[1]);
    ExpectNear(-0.2F, output[2]);
    ExpectNear(0.5F, output[3]);
}

void Downsample96kUsesContinuousTimeline() {
    const std::vector<float> input = {0.0F, 10.0F, 1.0F, 11.0F, 2.0F, 12.0F,
                                      3.0F, 13.0F, 4.0F, 14.0F, 5.0F, 15.0F};
    const auto output = Convert(96'000, 2, input);
    Expect(output.size() == 6, "96 kHz output length wrong");
    ExpectNear(0.0F, output[0]); ExpectNear(10.0F, output[1]);
    ExpectNear(2.0F, output[2]); ExpectNear(12.0F, output[3]);
    ExpectNear(4.0F, output[4]); ExpectNear(14.0F, output[5]);
}

void EmptySingleAndInvalidInputs() {
    LinearResampler resampler(44'100, 2);
    std::vector<float> output;
    Expect(resampler.Process(nullptr, 0, &output) == Error::Ok && resampler.Flush(&output) == Error::Ok && output.empty(),
           "empty stream failed");
    Expect(resampler.Process(nullptr, 0, &output) == Error::InvalidState, "process after flush accepted");
    resampler.Reset();
    const std::array<float, 2> frame = {0.75F, -0.5F};
    Expect(resampler.Process(frame.data(), 1, &output) == Error::Ok && resampler.Flush(&output) == Error::Ok,
           "single frame failed");
    Expect(
        output.size() == 4 &&
            output[0] == frame[0] &&
            output[1] == frame[1] &&
            output[2] == frame[0] &&
            output[3] == frame[1],
        "single stereo frame did not preserve the ceil-duration terminal sample");
    LinearResampler invalid_rate(0, 1);
    Expect(invalid_rate.Process(frame.data(), 1, &output) == Error::InvalidArgument, "zero rate accepted");
    LinearResampler invalid_channels(44'100, 0);
    Expect(invalid_channels.Process(frame.data(), 1, &output) == Error::InvalidArgument, "zero channels accepted");
    LinearResampler valid(44'100, 1);
    Expect(valid.Process(nullptr, 1, &output) == Error::InvalidArgument, "null nonempty input accepted");
    Expect(valid.Process(reinterpret_cast<const float*>(1), UINT64_MAX, &output) == Error::Overflow,
           "overflowing frame count accepted");
}

void OutputLengthStaysWithinOneFrame() {
    constexpr std::uint64_t input_frames = 44'113;
    std::vector<float> input;
    input.reserve(static_cast<std::size_t>(input_frames));
    for (std::uint64_t index = 0; index != input_frames; ++index) input.push_back(static_cast<float>(index % 7));
    const auto output = Convert(44'100, 1, input);
    const double ideal = static_cast<double>(input_frames) * 48'000.0 / 44'100.0;
    const double actual = static_cast<double>(output.size() / 2);
    Expect(std::fabs(actual - ideal) <= 1.0, "output duration error exceeded one frame");
}

}  // namespace

int main() {
    const std::array<std::pair<const char*, void (*)()>, 7> tests = {{{"48k passthrough", Passthrough48k},
        {"multi-block", MultiBlockMatchesSingleBlock}, {"mono and finite", MonoIsDuplicatedAndNonFiniteIsSilence},
        {"four-channel downmix", FourChannelInputIsDownmixedBeforeResampling},
        {"96k downsample", Downsample96kUsesContinuousTimeline}, {"empty and invalid", EmptySingleAndInvalidInputs},
        {"length error", OutputLengthStaysWithinOneFrame}}};
    try {
        for (const auto& test : tests) { test.second(); std::cout << "PASS " << test.first << '\n'; }
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
    return 0;
}
