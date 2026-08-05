#include "discontinuity_fade.h"

#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

void ExpectNear(float actual, float expected, const char* message) {
    if (std::abs(actual - expected) > 0.000001F) {
        std::cerr << message << ": expected " << expected << ", got " << actual << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void LeavesContinuousAudioBitExact() {
    std::array<float, 8> samples = {0.1F, -0.1F, 0.2F, -0.2F, 0.3F, -0.3F, 0.4F, -0.4F};
    const auto expected = samples;
    recorder::timeline::ApplyFadeInAtDiscontinuity(
        samples.data(), 4, recorder::timeline::DiscontinuityEdge::None);
    if (samples != expected) {
        std::cerr << "continuous audio was changed\n";
        std::exit(EXIT_FAILURE);
    }
}

void FadesBothChannelsOnlyAtAnExplicitSourceDiscontinuity() {
    std::array<float, 8> samples = {1.0F, -1.0F, 1.0F, -1.0F, 1.0F, -1.0F, 1.0F, -1.0F};
    recorder::timeline::ApplyFadeInAtDiscontinuity(
        samples.data(), 4, recorder::timeline::DiscontinuityEdge::SourceDiscontinuity, 4);
    ExpectNear(samples[0], 0.25F, "first left fade gain");
    ExpectNear(samples[1], -0.25F, "first right fade gain");
    ExpectNear(samples[4], 0.75F, "third left fade gain");
    ExpectNear(samples[5], -0.75F, "third right fade gain");
    ExpectNear(samples[6], 1.0F, "last left frame must reach unity");
    ExpectNear(samples[7], -1.0F, "last right frame must reach unity");
}

void BoundsFadeToTheAvailableResumeFrames() {
    std::array<float, 4> samples = {0.8F, -0.8F, 0.4F, -0.4F};
    recorder::timeline::ApplyFadeInAtDiscontinuity(
        samples.data(), 2, recorder::timeline::DiscontinuityEdge::SourceDiscontinuity, 240);
    ExpectNear(samples[0], 0.4F, "short fade first frame");
    ExpectNear(samples[1], -0.4F, "short fade first right frame");
    ExpectNear(samples[2], 0.4F, "short fade final frame");
    ExpectNear(samples[3], -0.4F, "short fade final right frame");
}

void CrossfadesFromAContinuousPreviousFrameWithoutDuckingToZero() {
    std::array<float, 8> samples = {1.0F, -1.0F, 1.0F, -1.0F, 1.0F, -1.0F, 1.0F, -1.0F};
    recorder::timeline::ApplyCrossfadeAtDiscontinuity(
        samples.data(), 4, recorder::timeline::DiscontinuityEdge::SourceDiscontinuity,
        0.5F, -0.5F, true, 4);
    ExpectNear(samples[0], 0.625F, "crossfade first left frame");
    ExpectNear(samples[1], -0.625F, "crossfade first right frame");
    ExpectNear(samples[4], 0.875F, "crossfade third left frame");
    ExpectNear(samples[6], 1.0F, "crossfade must reach new audio");
}

void AContinuousEqualSignalRemainsBitExact() {
    std::array<float, 8> samples = {0.3F, -0.2F, 0.3F, -0.2F, 0.3F, -0.2F, 0.3F, -0.2F};
    const auto expected = samples;
    recorder::timeline::ApplyCrossfadeAtDiscontinuity(
        samples.data(), 4, recorder::timeline::DiscontinuityEdge::SourceDiscontinuity,
        0.3F, -0.2F, true, 4);
    if (samples != expected) {
        std::cerr << "equal continuous signal was ducked\n";
        std::exit(EXIT_FAILURE);
    }
}

}  // namespace

int main() {
    LeavesContinuousAudioBitExact();
    FadesBothChannelsOnlyAtAnExplicitSourceDiscontinuity();
    BoundsFadeToTheAvailableResumeFrames();
    CrossfadesFromAContinuousPreviousFrameWithoutDuckingToZero();
    AContinuousEqualSignalRemainsBitExact();
    std::cout << "PASS discontinuity fade\n";
    return EXIT_SUCCESS;
}
