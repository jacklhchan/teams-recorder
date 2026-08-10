#include "short_impulse_repair.h"

#include <array>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
void Expect(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
}

int main() {
    try {
        std::vector<float> samples(120 * 2U, 0.02F);
        samples[60 * 2U] = 1.0F;
        samples[60 * 2U + 1U] = -1.0F;
        recorder::audio::ShortImpulseRepair repair;
        repair.Process(samples.data(), samples.size() / 2U, false);
        Expect(std::abs(samples[60 * 2U] - 0.02F) < 0.0001F &&
                   std::abs(samples[60 * 2U + 1U] - 0.02F) < 0.0001F,
               "isolated impulse was not repaired");
        samples.assign(120 * 2U, 0.02F);
        samples[60 * 2U] = samples[61 * 2U] = 1.0F;
        repair.Process(samples.data(), samples.size() / 2U, false);
        Expect(samples[60 * 2U] == 1.0F && samples[61 * 2U] == 1.0F,
               "multi-frame transient was unexpectedly repaired");
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n'; return 1;
    }
    std::cout << "PASS short impulse repair\n";
    return 0;
}
