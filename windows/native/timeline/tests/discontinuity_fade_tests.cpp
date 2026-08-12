#include "discontinuity_fade.h"

#include <array>
#include <cmath>
#include <iostream>
#include <stdexcept>

namespace {
void Expect(bool value, const char* message) { if (!value) throw std::runtime_error(message); }

void ExplicitDiscontinuityFadesFromSilence() {
    std::array<float, 8> samples{1, 1, 1, 1, 1, 1, 1, 1};
    recorder::timeline::ApplyCrossfadeAtDiscontinuity(
        samples.data(), 4, recorder::timeline::DiscontinuityEdge::SourceDiscontinuity,
        0, 0, false, 4);
    Expect(std::abs(samples[0] - 0.25F) < 0.0001F && samples[6] == 1.0F,
           "fade-in did not shape an explicit discontinuity");
}

void ContinuousDiscontinuityCrossfades() {
    std::array<float, 8> samples{1, 1, 1, 1, 1, 1, 1, 1};
    recorder::timeline::ApplyCrossfadeAtDiscontinuity(
        samples.data(), 4, recorder::timeline::DiscontinuityEdge::SourceDiscontinuity,
        -1, -1, true, 4);
    Expect(std::abs(samples[0] + 0.5F) < 0.0001F && samples[6] == 1.0F,
           "crossfade did not use the previous sample");
}
}  // namespace

int main() {
    try { ExplicitDiscontinuityFadesFromSilence(); ContinuousDiscontinuityCrossfades(); }
    catch (const std::exception& error) { std::cerr << "FAIL " << error.what() << '\n'; return 1; }
    std::cout << "PASS discontinuity fade\n";
    return 0;
}
