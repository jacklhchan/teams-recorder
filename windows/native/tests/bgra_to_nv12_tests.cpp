#include "bgra_to_nv12.h"

#include <cstdint>
#include <iostream>
#include <vector>

namespace {

bool Expect(bool condition, const char* message) {
    if (condition) return true;
    std::cerr << message << '\n';
    return false;
}

}  // namespace

int main() {
    // A wide white source must be letterboxed into the centre of a square NV12
    // canvas.  Black bars use video-range Y=16 / UV=128, not uninitialised
    // bytes, which makes the frame deterministic for encoder tests.
    std::vector<std::uint8_t> source(4U * 2U * 4U, 255U);
    std::vector<std::uint8_t> output;
    if (!Expect(recorder::video::ConvertBgraToNv12Letterboxed(
                    source.data(), 16U, 4U, 2U, 8U, 8U, &output),
                "Expected valid BGRA to convert.")) return 1;
    if (!Expect(output.size() == 96U, "Unexpected NV12 output size.")) return 1;
    if (!Expect(output[0] == 16U && output[8U * 2U] > 200U,
                "Expected deterministic letterbox bars and visible source content.")) return 1;
    if (!Expect(output[64U] == 128U, "Expected neutral UV in letterbox bar.")) return 1;

    // NV12 requires even output geometry.  Invalid input cannot be accepted
    // and cannot mutate a caller's previous output buffer.
    const auto before = output;
    if (!Expect(!recorder::video::ConvertBgraToNv12Letterboxed(
                    source.data(), 16U, 4U, 2U, 7U, 8U, &output),
                "Odd output width must be rejected.")) return 1;
    if (!Expect(output == before, "Rejected conversion must retain caller output.")) return 1;

    return 0;
}
