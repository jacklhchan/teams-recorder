#pragma once

#include "dynamic_video_route.h"

#include <cstdint>

namespace recorder::video {

// Describes the exact WGC stream that produced the last frame copied into
// owned memory. A frame may be repeated only while every privacy fence still
// matches. The frame-pool epoch changes on resize and prevents an old-geometry
// image from being held across that boundary.
class TrustedVideoFrameHold final {
public:
    void Remember(std::uintptr_t capture_token,
                  std::uint64_t route_generation,
                  ExactWindowIdentity identity,
                  std::uint64_t frame_pool_epoch) noexcept {
        capture_token_ = capture_token;
        route_generation_ = route_generation;
        identity_ = identity;
        frame_pool_epoch_ = frame_pool_epoch;
        valid_ = capture_token != 0 && identity.IsUsable();
    }

    bool CanRepeat(std::uintptr_t capture_token,
                   std::uint64_t route_generation,
                   ExactWindowIdentity identity,
                   std::uint64_t frame_pool_epoch,
                   bool route_allows_frame,
                   bool capture_running) const noexcept {
        return valid_ && route_allows_frame && capture_running &&
            capture_token != 0 && capture_token == capture_token_ &&
            route_generation == route_generation_ && identity == identity_ &&
            frame_pool_epoch == frame_pool_epoch_;
    }

    void Forget() noexcept {
        valid_ = false;
        capture_token_ = 0;
        route_generation_ = 0;
        identity_ = {};
        frame_pool_epoch_ = 0;
    }

    bool has_frame() const noexcept { return valid_; }

private:
    std::uintptr_t capture_token_ = 0;
    std::uint64_t route_generation_ = 0;
    ExactWindowIdentity identity_{};
    std::uint64_t frame_pool_epoch_ = 0;
    bool valid_ = false;
};

}  // namespace recorder::video
