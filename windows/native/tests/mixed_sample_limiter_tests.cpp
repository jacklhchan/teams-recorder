#include "mixed_sample_limiter.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

void require_near(const float actual, const float expected, const char* message) {
    if (std::abs(actual - expected) > 0.000001F) {
        std::cerr << message << ": expected " << expected << ", got " << actual << '\n';
        std::exit(EXIT_FAILURE);
    }
}

}  // namespace

int main() {
    using recorder::audio::limit_mixed_sample;
    require_near(limit_mixed_sample(0.5F), 0.5F, "positive in-range sample changed");
    require_near(limit_mixed_sample(-0.5F), -0.5F, "negative in-range sample changed");
    require_near(limit_mixed_sample(1.4F), 1.0F, "positive overflow was not bounded");
    require_near(limit_mixed_sample(-1.4F), -1.0F, "negative overflow was not bounded");
    return EXIT_SUCCESS;
}
