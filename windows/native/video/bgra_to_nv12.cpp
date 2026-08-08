#include "bgra_to_nv12.h"

#include <algorithm>
#include <limits>

namespace recorder::video {
namespace {
std::uint8_t Clip(int value) noexcept { return static_cast<std::uint8_t>((std::max)(0, (std::min)(255, value))); }
void ToYuv(const std::uint8_t* pixel, int* y, int* u, int* v) noexcept {
    const int b = pixel[0]; const int g = pixel[1]; const int r = pixel[2];
    *y = Clip(((47 * r + 157 * g + 16 * b + 128) >> 8) + 16);
    *u = Clip(((-26 * r - 87 * g + 112 * b + 128) >> 8) + 128);
    *v = Clip(((112 * r - 102 * g - 10 * b + 128) >> 8) + 128);
}
}

bool ConvertBgraToNv12Letterboxed(const std::uint8_t* source, std::uint32_t source_stride,
                                  std::uint32_t source_width, std::uint32_t source_height,
                                  std::uint32_t target_width, std::uint32_t target_height,
                                  std::vector<std::uint8_t>* target) noexcept {
    const std::uint64_t minimum_source_stride = static_cast<std::uint64_t>(source_width) * 4U;
    if (source == nullptr || target == nullptr || source_width == 0 || source_height == 0 ||
        minimum_source_stride > std::numeric_limits<std::uint32_t>::max() ||
        source_stride < minimum_source_stride || target_width < 2 || target_height < 2 ||
        target_width % 2 != 0 || target_height % 2 != 0) return false;
    const std::uint64_t target_bytes = static_cast<std::uint64_t>(target_width) * target_height * 3U / 2U;
    if (target_bytes > std::numeric_limits<std::size_t>::max()) return false;
    try {
        target->assign(static_cast<std::size_t>(target_bytes), static_cast<std::uint8_t>(16U));
    } catch (...) {
        target->clear();
        return false;
    }
    std::fill(target->begin() + static_cast<std::size_t>(target_width) * target_height, target->end(), static_cast<std::uint8_t>(128U));
    const double scale = (std::min)(static_cast<double>(target_width) / source_width,
                                    static_cast<double>(target_height) / source_height);
    const auto content_width = static_cast<std::uint32_t>(source_width * scale) & ~1U;
    const auto content_height = static_cast<std::uint32_t>(source_height * scale) & ~1U;
    if (content_width == 0 || content_height == 0) return false;
    // NV12 chroma samples are 2x2, therefore content origin must be even.
    const auto left = ((target_width - content_width) / 2U) & ~1U;
    const auto top = ((target_height - content_height) / 2U) & ~1U;
    auto* y_plane = target->data();
    auto* uv_plane = y_plane + static_cast<std::size_t>(target_width) * target_height;
    for (std::uint32_t y = 0; y < content_height; ++y) {
        const auto source_y = (std::min)(source_height - 1U, static_cast<std::uint32_t>(y / scale));
        for (std::uint32_t x = 0; x < content_width; ++x) {
            const auto source_x = (std::min)(source_width - 1U, static_cast<std::uint32_t>(x / scale));
            int luma = 0, unused_u = 0, unused_v = 0;
            ToYuv(source + static_cast<std::size_t>(source_y) * source_stride + source_x * 4U, &luma, &unused_u, &unused_v);
            y_plane[static_cast<std::size_t>(top + y) * target_width + left + x] = static_cast<std::uint8_t>(luma);
        }
    }
    for (std::uint32_t y = 0; y < content_height; y += 2U) for (std::uint32_t x = 0; x < content_width; x += 2U) {
        int sum_u = 0, sum_v = 0;
        for (std::uint32_t dy = 0; dy != 2; ++dy) for (std::uint32_t dx = 0; dx != 2; ++dx) {
            const auto source_y = (std::min)(source_height - 1U, static_cast<std::uint32_t>((y + dy) / scale));
            const auto source_x = (std::min)(source_width - 1U, static_cast<std::uint32_t>((x + dx) / scale));
            int ignored_y = 0, u = 0, v = 0;
            ToYuv(source + static_cast<std::size_t>(source_y) * source_stride + source_x * 4U, &ignored_y, &u, &v);
            sum_u += u; sum_v += v;
        }
        const auto index = static_cast<std::size_t>((top + y) / 2U) * target_width + left + x;
        uv_plane[index] = static_cast<std::uint8_t>(sum_u / 4);
        uv_plane[index + 1] = static_cast<std::uint8_t>(sum_v / 4);
    }
    return true;
}

}  // namespace recorder::video
