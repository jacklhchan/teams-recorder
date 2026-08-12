#include "system_render_headroom.h"

#include <array>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>

namespace {
void Expect(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
}

int main() {
    try {
        std::array<float, 4> samples{1.4142135F, -1.4142135F,
                                     std::numeric_limits<float>::infinity(), 0.5F};
        recorder::audio::ApplySystemRenderHeadroom(samples.data(), samples.size());
        Expect(std::abs(samples[0]) < 1.0F && std::abs(samples[1]) < 1.0F,
               "headroom did not keep observed loopback peaks below unity");
        Expect(samples[2] == 0.0F && std::abs(samples[3] - 0.35F) < 0.0001F,
               "headroom did not preserve finite samples safely");
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n'; return 1;
    }
    std::cout << "PASS system render headroom\n";
    return 0;
}
