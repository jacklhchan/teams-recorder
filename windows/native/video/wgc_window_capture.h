#pragma once

#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace recorder::video {

enum class WgcWindowCaptureStatus {
    kOk,
    kInvalidArgument,
    kUnsupportedTarget,
    kPlatformUnavailable,
    kInitializationFailed,
    kCaptureFailed,
    kInvalidState,
};

struct OwnedBgraFrame {
    std::int32_t width = 0;
    std::int32_t height = 0;
    std::int32_t stride_bytes = 0;
    // WGC's SystemRelativeTime in 100-nanosecond units. The vector is owned by
    // this object and remains valid after the WGC frame has been closed.
    std::int64_t system_relative_time_100ns = 0;
    std::vector<std::uint8_t> pixels;
};

struct WgcWindowCaptureStats {
    std::uint64_t received_frames = 0;
    std::uint64_t delivered_frames = 0;
    std::uint64_t dropped_frames = 0;
    std::uint64_t frame_pool_recreates = 0;
};

using OwnedBgraFrameCallback = std::function<void(OwnedBgraFrame&&)>;

class WgcWindowCapture final {
public:
    WgcWindowCapture();
    ~WgcWindowCapture();
    WgcWindowCapture(const WgcWindowCapture&) = delete;
    WgcWindowCapture& operator=(const WgcWindowCapture&) = delete;

    // Starts an independent free-threaded WGC session for one top-level HWND.
    // The callback runs on the capture worker and must return promptly. Frames
    // are copied to owned BGRA8 storage before the callback is invoked.
    WgcWindowCaptureStatus Start(HWND window, OwnedBgraFrameCallback callback);
    WgcWindowCaptureStatus Stop();
    [[nodiscard]] bool is_running() const;
    [[nodiscard]] WgcWindowCaptureStats stats() const;
    [[nodiscard]] std::string last_error() const;

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

const char* WgcWindowCaptureStatusName(WgcWindowCaptureStatus status) noexcept;

}  // namespace recorder::video
