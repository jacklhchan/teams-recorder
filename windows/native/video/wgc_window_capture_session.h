#pragma once

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace recorder::video {

// A WGC target is deliberately an exact window identity rather than a title,
// process name, monitor, or desktop source.  The creation timestamp is the
// Windows FILETIME value returned by GetProcessTimes and prevents a recycled
// PID from silently becoming capture.
struct WgcWindowTargetIdentity {
    HWND window = nullptr;
    DWORD process_id = 0;
    std::uint64_t process_creation_time_100ns = 0;
};

enum class WgcCaptureError : std::uint8_t {
    kOk,
    kInvalidArgument,
    kInvalidState,
    kTargetNotLive,
    kTargetIdentityMismatch,
    kTargetRejected,
    kPlatformUnavailable,
    kItemCreationFailed,
    kDeviceInitializationFailed,
    kFramePoolCreationFailed,
    kTargetLost,
    kFrameCopyFailed,
    kFrameConversionFailed,
    kInternalFailure,
};

struct WgcCaptureResult {
    WgcCaptureError error = WgcCaptureError::kInvalidState;
    HRESULT hresult = E_FAIL;
    // This is intentionally generic: callers must not persist HWND, PID,
    // creation time, title, bounds, or any captured pixels in diagnostics.
    std::string detail;

    bool succeeded() const noexcept { return error == WgcCaptureError::kOk; }
};

const char* WgcCaptureErrorName(WgcCaptureError error) noexcept;

// Captures a stable identity for a live top-level HWND. It records no title or
// process path. Start rechecks all three values before creating WGC and while
// frames are accepted.
WgcCaptureResult BuildWgcWindowTargetIdentity(
    HWND window, WgcWindowTargetIdentity* target);

struct WgcWindowCaptureConfig {
    WgcWindowTargetIdentity target{};
    // The initial MP4 path supports an even H.264 canvas up to 1920x1080.
    // Frames are aspect-fit/letterboxed into this immutable canvas so WGC
    // resize and DPI changes never change the downstream encoder format.
    std::uint32_t canvas_width = 0;
    std::uint32_t canvas_height = 0;
    // The queue never blocks WGC.  A full queue drops the newest video frame;
    // it never delays audio or substitutes any other capture source.
    std::size_t max_queued_frames = 3;
};

struct WgcNv12Frame {
    std::vector<std::uint8_t> bytes;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t stride = 0;
    // WGC SystemRelativeTime in QPC-derived 100 ns units.  The mux lifecycle
    // maps this through VideoPtsMapper against the shared audio origin.
    std::uint64_t system_relative_time_100ns = 0;
};

enum class WgcWindowCaptureState : std::uint8_t {
    kIdle,
    kStarting,
    kRunning,
    kStopping,
    kStopped,
    kFailed,
};

struct WgcCaptureStats {
    std::uint64_t frames_arrived = 0;
    std::uint64_t frames_enqueued = 0;
    std::uint64_t frames_dequeued = 0;
    std::uint64_t frames_dropped_queue_full = 0;
    std::uint64_t frames_dropped_invalid = 0;
    std::uint64_t frames_dropped_copy_failure = 0;
    std::uint64_t frames_dropped_conversion_failure = 0;
    std::uint64_t frame_pool_recreations = 0;
    std::uint32_t latest_source_width = 0;
    std::uint32_t latest_source_height = 0;
};

// A background exact-HWND Windows Graphics Capture producer.  It owns every
// WGC/D3D object on its worker session, copies each frame into owned CPU NV12
// bytes, and exposes only a bounded queue. It has no desktop, monitor, picker,
// or automatic reselect fallback path.
class WgcWindowCaptureSession final {
public:
    WgcWindowCaptureSession();
    ~WgcWindowCaptureSession();
    WgcWindowCaptureSession(const WgcWindowCaptureSession&) = delete;
    WgcWindowCaptureSession& operator=(const WgcWindowCaptureSession&) = delete;

    // Synchronous only until the exact HWND WGC session is initialized. A
    // successful result means StartCapture was reached, not that an output
    // frame has already been dequeued.
    WgcCaptureResult Start(const WgcWindowCaptureConfig& config);
    // Idempotent. It prevents new callback work, waits for any in-flight CPU
    // copy/conversion, then closes the session/frame pool on its owner thread.
    void Stop() noexcept;

    // Neither operation blocks the WGC callback. WaitPopFrame returns false
    // after timeout or once the session has terminated with no queued frame.
    bool TryPopFrame(WgcNv12Frame* frame);
    bool WaitPopFrame(WgcNv12Frame* frame, DWORD timeout_milliseconds);

    bool IsRunning() const noexcept;
    WgcWindowCaptureState State() const noexcept;
    WgcCaptureStats Stats() const noexcept;
    WgcCaptureResult LastResult() const;

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace recorder::video
