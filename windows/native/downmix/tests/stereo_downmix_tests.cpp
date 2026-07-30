#include "stereo_downmix.h"

#include <array>
#include <cmath>
#include <exception>
#include <iostream>
#include <limits>
#include <stdexcept>

namespace {

void Expect(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

void ExpectNear(float expected, float actual) {
    if (std::fabs(expected - actual) > 0.00001F) throw std::runtime_error("sample mismatch");
}

void MonoDuplicates() {
    const std::array<float, 1> input = {0.25F};
    float left = 0.0F;
    float right = 0.0F;
    Expect(recorder::downmix::DownmixFrameToStereo(input.data(), 1, &left, &right), "mono rejected");
    ExpectNear(0.25F, left);
    ExpectNear(0.25F, right);
}

void StereoPassesThroughExactly() {
    const std::array<float, 2> input = {-0.75F, 0.5F};
    float left = 0.0F;
    float right = 0.0F;
    Expect(recorder::downmix::DownmixFrameToStereo(input.data(), 2, &left, &right), "stereo rejected");
    ExpectNear(input[0], left);
    ExpectNear(input[1], right);
}

void FourChannelsPairByIndex() {
    const std::array<float, 4> input = {0.2F, 0.4F, 0.6F, -0.2F};
    float left = 0.0F;
    float right = 0.0F;
    Expect(recorder::downmix::DownmixFrameToStereo(input.data(), 4, &left, &right), "four-channel rejected");
    ExpectNear(0.4F, left);
    ExpectNear(0.1F, right);
}

void NonFiniteIsSilenceAndOddLayoutsRemainPredictable() {
    const std::array<float, 3> input = {
        std::numeric_limits<float>::quiet_NaN(), 0.75F,
        std::numeric_limits<float>::infinity()};
    float left = 0.0F;
    float right = 0.0F;
    Expect(recorder::downmix::DownmixFrameToStereo(input.data(), 3, &left, &right), "three-channel rejected");
    ExpectNear(0.0F, left);
    ExpectNear(0.75F, right);
}

void InvalidArgumentsDoNotWriteOutput() {
    const std::array<float, 1> input = {0.5F};
    float left = 1.0F;
    float right = -1.0F;
    Expect(!recorder::downmix::DownmixFrameToStereo(input.data(), 0, &left, &right), "zero channels accepted");
    ExpectNear(1.0F, left);
    ExpectNear(-1.0F, right);
}

}  // namespace

int main() {
    try {
        MonoDuplicates();
        StereoPassesThroughExactly();
        FourChannelsPairByIndex();
        NonFiniteIsSilenceAndOddLayoutsRemainPredictable();
        InvalidArgumentsDoNotWriteOutput();
        std::cout << "PASS stereo downmix\n";
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
    return 0;
}
