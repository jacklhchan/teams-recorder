#pragma once

#include <windows.h>

#include <cstdint>
#include <string>

namespace recorder::video {

// The base probe only creates a GraphicsCaptureItem.  The separate frame probe
// below starts a short-lived exact-HWND session to prove that frames arrive;
// neither probe copies pixels, encodes media, or falls back to desktop capture.
enum class WgcProbeStatus {
    kSupported,
    kInvalidWindow,
    kHiddenWindow,
    kChildWindow,
    kCloakedWindow,
    kProtectedWindow,
    kElevatedTarget,
    kApartmentInitializationFailed,
    kPlatformUnavailable,
    kCreateItemFailed,
    kDeviceInitializationFailed,
    kFrameCaptureFailed,
    kFrameTimeout,
};

// The COM apartment observed while creating the item. Existing apartments are
// deliberately preserved; the probe initializes MTA only on an uninitialized
// thread.
enum class WgcProbeApartment {
    kUnknown,
    kSingleThreaded,
    kMainSingleThreaded,
    kMultiThreaded,
    kNeutral,
};

struct WgcProbeResult {
    WgcProbeStatus status = WgcProbeStatus::kInvalidWindow;
    HRESULT hresult = E_FAIL;
    DWORD process_id = 0;
    DWORD target_integrity_rid = 0;
    DWORD current_integrity_rid = 0;
    WgcProbeApartment apartment = WgcProbeApartment::kUnknown;
    bool apartment_initialized_by_probe = false;
    std::uint64_t frames_observed = 0;
    std::uint32_t first_frame_width = 0;
    std::uint32_t first_frame_height = 0;
    std::string diagnostic;
};

WgcProbeResult ProbeWindowGraphicsCapture(HWND window);
WgcProbeResult ProbeWindowGraphicsCaptureFrames(HWND window,
                                                 std::uint64_t required_frames,
                                                 DWORD timeout_milliseconds);
const char* WgcProbeStatusName(WgcProbeStatus status) noexcept;
const char* WgcProbeApartmentName(WgcProbeApartment apartment) noexcept;

}  // namespace recorder::video
