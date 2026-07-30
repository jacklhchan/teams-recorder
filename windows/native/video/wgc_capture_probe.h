#pragma once

#include <windows.h>

#include <string>

namespace recorder::video {

// This probe only creates a GraphicsCaptureItem.  It never creates a frame
// pool/session, starts capture, or copies pixels.
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
    std::string diagnostic;
};

WgcProbeResult ProbeWindowGraphicsCapture(HWND window);
const char* WgcProbeStatusName(WgcProbeStatus status) noexcept;
const char* WgcProbeApartmentName(WgcProbeApartment apartment) noexcept;

}  // namespace recorder::video
