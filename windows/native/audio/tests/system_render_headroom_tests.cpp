#include "system_render_headroom.h"

#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

namespace {

constexpr float kTolerance = 0.000001F;

void Expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void ObservedSqrtTwoPeaksStayWithinPcmRange() {
    const float observed_peak = std::sqrt(2.0F);
    for (const char* version : {"v106", "v107", "v108"}) {
        const float scaled = recorder::audio::ApplySystemRenderHeadroomSample(observed_peak);
        Expect(std::isfinite(scaled), "headroom output was not finite");
        Expect(std::abs(scaled) <= 1.0F + kTolerance,
               "observed sqrt(2) peak exceeded the PCM range");
        Expect(scaled <= 0.99F,
               "observed sqrt(2) peak did not retain safety headroom");
        (void)version;
    }
}

void ObservedCorpusPeaksCannotReachTheHardLimiter() {
    constexpr std::array<float, 3U> observed_peaks = {
        1.414151906967163F,
        1.414192676544189F,
        1.414213418960571F,
    };
    for (const float peak : observed_peaks) {
        Expect(recorder::audio::ApplySystemRenderHeadroomSample(peak) < 1.0F,
               "an observed Realtek loopback peak still reached the hard limiter");
    }
}

void WithinRangeSamplesScaleLinearly() {
    constexpr std::array<float, 5U> input = {-0.75F, -0.25F, 0.0F, 0.25F, 0.75F};
    for (const float value : input) {
        const float actual = recorder::audio::ApplySystemRenderHeadroomSample(value);
        const float expected = value * recorder::audio::kSystemRenderHeadroomGain;
        Expect(std::abs(actual - expected) <= kTolerance,
               "within-range sample was not scaled linearly");
    }
}

void NonFiniteSamplesFailSafeToSilence() {
    Expect(recorder::audio::ApplySystemRenderHeadroomSample(
               std::numeric_limits<float>::quiet_NaN()) == 0.0F,
           "NaN did not fail safe to silence");
    Expect(recorder::audio::ApplySystemRenderHeadroomSample(
               std::numeric_limits<float>::infinity()) == 0.0F,
           "+infinity did not fail safe to silence");
    Expect(recorder::audio::ApplySystemRenderHeadroomSample(
               -std::numeric_limits<float>::infinity()) == 0.0F,
           "-infinity did not fail safe to silence");
}

void InPlaceProcessingPreservesDurationAndChannels() {
    constexpr std::size_t kStereoChannels = 2U;
    constexpr std::size_t kFrames = 7U;
    std::vector<float> samples(kFrames * kStereoChannels, 0.5F);
    const std::size_t original_sample_count = samples.size();
    const std::size_t original_frames = samples.size() / kStereoChannels;

    recorder::audio::ApplySystemRenderHeadroom(samples.data(), samples.size());

    Expect(samples.size() == original_sample_count,
           "headroom processing changed the sample count");
    Expect(samples.size() / kStereoChannels == original_frames,
           "headroom processing changed the duration or channel layout");
    for (const float sample : samples) {
        Expect(std::abs(sample - 0.5F * recorder::audio::kSystemRenderHeadroomGain) <=
                   kTolerance,
               "in-place headroom processing changed a sample unexpectedly");
    }
}

}  // namespace

int main() {
    ObservedSqrtTwoPeaksStayWithinPcmRange();
    ObservedCorpusPeaksCannotReachTheHardLimiter();
    WithinRangeSamplesScaleLinearly();
    NonFiniteSamplesFailSafeToSilence();
    InPlaceProcessingPreservesDurationAndChannels();
    std::cout << "PASS system render headroom\n";
    return EXIT_SUCCESS;
}
