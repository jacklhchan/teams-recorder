#include "short_impulse_repair.h"

#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

namespace {

constexpr std::size_t kFrames = 160U;
constexpr std::size_t kClickFrame = 80U;

void Expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

std::vector<float> QuietStereo(float left = 0.05F, float right = -0.04F) {
    std::vector<float> samples(kFrames * 2U);
    for (std::size_t frame = 0; frame < kFrames; ++frame) {
        samples[frame * 2U] = left;
        samples[frame * 2U + 1U] = right;
    }
    return samples;
}

void LeavesCleanAudioBitExact() {
    auto samples = QuietStereo();
    const auto expected = samples;
    recorder::audio::ShortImpulseRepair repair;
    repair.Process(samples.data(), kFrames, false);
    Expect(samples == expected, "clean audio was modified");
    Expect(repair.stats().repaired_frames == 0, "clean audio reported a repair");
}

void RepairsAnIsolatedStereoFrame() {
    auto samples = QuietStereo();
    samples[kClickFrame * 2U] = 0.99F;
    samples[kClickFrame * 2U + 1U] = -0.99F;
    recorder::audio::ShortImpulseRepair repair;
    repair.Process(samples.data(), kFrames, false);
    Expect(std::abs(samples[kClickFrame * 2U] - 0.05F) < 0.000001F,
           "left isolated impulse was not interpolated");
    Expect(std::abs(samples[kClickFrame * 2U + 1U] + 0.04F) < 0.000001F,
           "right isolated impulse was not interpolated");
    Expect(repair.stats().candidate_frames == 1, "stereo candidate count changed");
    Expect(repair.stats().repaired_frames == 1, "stereo repair count changed");
    Expect(repair.stats().repaired_samples == 2, "stereo repaired sample count changed");
}

void RepairsOnlyTheAffectedChannel() {
    auto samples = QuietStereo();
    const auto right_before = samples[kClickFrame * 2U + 1U];
    samples[kClickFrame * 2U] = -0.99F;
    recorder::audio::ShortImpulseRepair repair;
    repair.Process(samples.data(), kFrames, false);
    Expect(std::abs(samples[kClickFrame * 2U] - 0.05F) < 0.000001F,
           "single-channel impulse was not repaired");
    Expect(samples[kClickFrame * 2U + 1U] == right_before,
           "unaffected stereo channel was modified");
}

void LeavesLegitimateStepsAndMultiFrameTransientsBitExact() {
    auto samples = QuietStereo();
    for (std::size_t frame = kClickFrame; frame < kFrames; ++frame) {
        samples[frame * 2U] = 0.95F;
        samples[frame * 2U + 1U] = -0.95F;
    }
    const auto step_expected = samples;
    recorder::audio::ShortImpulseRepair repair;
    repair.Process(samples.data(), kFrames, false);
    Expect(samples == step_expected, "a legitimate hard step was modified");

    samples = QuietStereo();
    samples[kClickFrame * 2U] = 0.99F;
    samples[(kClickFrame + 1U) * 2U] = 0.99F;
    const auto pulse_expected = samples;
    repair.Reset();
    repair.Process(samples.data(), kFrames, false);
    Expect(samples == pulse_expected, "a multi-frame transient was modified");
}

void DiscontinuityPacketsAreNeverInterpolated() {
    auto samples = QuietStereo();
    samples[kClickFrame * 2U] = 0.99F;
    const auto expected = samples;
    recorder::audio::ShortImpulseRepair repair;
    repair.Process(samples.data(), kFrames, true);
    Expect(samples == expected, "discontinuity packet was modified");
    Expect(repair.stats().skipped_discontinuity_packets == 1,
           "discontinuity skip was not counted");
}

void NonFiniteAndBoundarySamplesFailClosed() {
    auto samples = QuietStereo();
    samples[2U] = 0.99F;
    samples[kClickFrame * 2U] = std::numeric_limits<float>::quiet_NaN();
    const auto boundary = samples[2U];
    recorder::audio::ShortImpulseRepair repair;
    repair.Process(samples.data(), kFrames, false);
    Expect(samples[2U] == boundary, "near-boundary sample was modified");
    Expect(std::isnan(samples[kClickFrame * 2U]), "non-finite sample was modified");
    Expect(repair.stats().repaired_frames == 0, "fail-closed input reported a repair");
}

}  // namespace

int main() {
    LeavesCleanAudioBitExact();
    RepairsAnIsolatedStereoFrame();
    RepairsOnlyTheAffectedChannel();
    LeavesLegitimateStepsAndMultiFrameTransientsBitExact();
    DiscontinuityPacketsAreNeverInterpolated();
    NonFiniteAndBoundarySamplesFailClosed();
    std::cout << "PASS short impulse repair\n";
    return EXIT_SUCCESS;
}
