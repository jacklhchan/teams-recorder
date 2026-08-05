#include "wgc_capture_probe.h"

#include <dwmapi.h>
#include <roapi.h>
#include <windows.graphics.capture.interop.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/base.h>

#include <sstream>

namespace recorder::video {
namespace {

constexpr DWORD kIntegrityMedium = SECURITY_MANDATORY_MEDIUM_RID;

DWORD IntegrityRidForProcess(DWORD process_id, HRESULT* failure) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
    if (process == nullptr) {
        *failure = HRESULT_FROM_WIN32(GetLastError());
        return 0;
    }
    HANDLE token = nullptr;
    if (!OpenProcessToken(process, TOKEN_QUERY, &token)) {
        *failure = HRESULT_FROM_WIN32(GetLastError());
        CloseHandle(process);
        return 0;
    }
    DWORD bytes = 0;
    (void)GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &bytes);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || bytes == 0) {
        *failure = HRESULT_FROM_WIN32(GetLastError());
        CloseHandle(token);
        CloseHandle(process);
        return 0;
    }
    std::string buffer(bytes, '\0');
    if (!GetTokenInformation(token, TokenIntegrityLevel, buffer.data(), bytes, &bytes)) {
        *failure = HRESULT_FROM_WIN32(GetLastError());
        CloseHandle(token);
        CloseHandle(process);
        return 0;
    }
    const auto* const label = reinterpret_cast<const TOKEN_MANDATORY_LABEL*>(buffer.data());
    DWORD rid = 0;
    if (label->Label.Sid != nullptr) {
        const DWORD count = *GetSidSubAuthorityCount(label->Label.Sid);
        rid = *GetSidSubAuthority(label->Label.Sid, count - 1U);
    }
    CloseHandle(token);
    CloseHandle(process);
    *failure = S_OK;
    return rid;
}

std::string HresultText(HRESULT value) {
    std::ostringstream stream;
    stream << "0x" << std::hex << static_cast<unsigned long>(value);
    char message[512]{};
    const DWORD characters = FormatMessageA(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, static_cast<DWORD>(value), 0, message,
        static_cast<DWORD>(sizeof(message)), nullptr);
    if (characters != 0) {
        std::string description(message, characters);
        while (!description.empty() &&
               (description.back() == '\r' || description.back() == '\n' || description.back() == ' ')) {
            description.pop_back();
        }
        stream << " (" << description << ')';
    }
    return stream.str();
}

WgcProbeResult Failure(WgcProbeStatus status, HRESULT hr, std::string diagnostic) {
    WgcProbeResult result{};
    result.status = status;
    result.hresult = hr;
    result.diagnostic = std::move(diagnostic);
    return result;
}

WgcProbeApartment ToProbeApartment(APTTYPE apartment) noexcept {
    switch (apartment) {
    case APTTYPE_STA: return WgcProbeApartment::kSingleThreaded;
    case APTTYPE_MAINSTA: return WgcProbeApartment::kMainSingleThreaded;
    case APTTYPE_MTA: return WgcProbeApartment::kMultiThreaded;
    case APTTYPE_NA: return WgcProbeApartment::kNeutral;
    default: return WgcProbeApartment::kUnknown;
    }
}

class ProbeApartment final {
public:
    HRESULT Initialize() noexcept {
        APTTYPE apartment = APTTYPE_CURRENT;
        APTTYPEQUALIFIER qualifier = APTTYPEQUALIFIER_NONE;
        const HRESULT existing_apartment = CoGetApartmentType(&apartment, &qualifier);
        if (SUCCEEDED(existing_apartment)) {
            apartment_ = ToProbeApartment(apartment);
            return S_OK;
        }
        if (existing_apartment != CO_E_NOTINITIALIZED) {
            return existing_apartment;
        }

        const HRESULT initialized = RoInitialize(RO_INIT_MULTITHREADED);
        if (FAILED(initialized)) {
            return initialized;
        }
        initialized_by_probe_ = true;
        apartment_ = WgcProbeApartment::kMultiThreaded;
        return S_OK;
    }

    ~ProbeApartment() {
        if (initialized_by_probe_) {
            // C++/WinRT caches activation factories process-wide.  A probe can
            // be the first WinRT caller in a command-line or unpackaged host,
            // in which case this apartment owns the matching RoInitialize.
            // Drop factories obtained in that apartment before RoUninitialize;
            // otherwise a later capture worker can reuse a proxy whose module
            // was torn down with the probe apartment (observed as an AV while
            // AddRef'ing IGraphicsCaptureItemInterop).
            winrt::clear_factory_cache();
            RoUninitialize();
        }
    }

    WgcProbeApartment apartment() const noexcept { return apartment_; }
    bool initialized_by_probe() const noexcept { return initialized_by_probe_; }

private:
    WgcProbeApartment apartment_ = WgcProbeApartment::kUnknown;
    bool initialized_by_probe_ = false;
};

}  // namespace

const char* WgcProbeStatusName(WgcProbeStatus status) noexcept {
    switch (status) {
    case WgcProbeStatus::kSupported: return "supported";
    case WgcProbeStatus::kInvalidWindow: return "invalid-window";
    case WgcProbeStatus::kHiddenWindow: return "hidden-window";
    case WgcProbeStatus::kChildWindow: return "child-window";
    case WgcProbeStatus::kCloakedWindow: return "cloaked-window";
    case WgcProbeStatus::kProtectedWindow: return "protected-window";
    case WgcProbeStatus::kElevatedTarget: return "elevated-target";
    case WgcProbeStatus::kApartmentInitializationFailed: return "apartment-initialization-failed";
    case WgcProbeStatus::kPlatformUnavailable: return "platform-unavailable";
    case WgcProbeStatus::kCreateItemFailed: return "create-item-failed";
    }
    return "unknown";
}

const char* WgcProbeApartmentName(WgcProbeApartment apartment) noexcept {
    switch (apartment) {
    case WgcProbeApartment::kUnknown: return "unknown";
    case WgcProbeApartment::kSingleThreaded: return "sta";
    case WgcProbeApartment::kMainSingleThreaded: return "main-sta";
    case WgcProbeApartment::kMultiThreaded: return "mta";
    case WgcProbeApartment::kNeutral: return "neutral";
    }
    return "unknown";
}

WgcProbeResult ProbeWindowGraphicsCapture(HWND window) {
    if (!IsWindow(window)) {
        return Failure(WgcProbeStatus::kInvalidWindow, E_INVALIDARG, "HWND is not a live window.");
    }
    if (!IsWindowVisible(window)) {
        return Failure(WgcProbeStatus::kHiddenWindow, E_ACCESSDENIED, "Refusing a hidden window.");
    }
    if ((GetWindowLongPtrW(window, GWL_STYLE) & WS_CHILD) != 0) {
        return Failure(WgcProbeStatus::kChildWindow, E_INVALIDARG, "Refusing a child HWND; a visible top-level window is required.");
    }
    DWORD cloaked = 0;
    if (SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) && cloaked != 0) {
        return Failure(WgcProbeStatus::kCloakedWindow, E_ACCESSDENIED, "Refusing a cloaked window.");
    }
    DWORD affinity = WDA_NONE;
    if (GetWindowDisplayAffinity(window, &affinity) &&
        (affinity == WDA_MONITOR || affinity == WDA_EXCLUDEFROMCAPTURE)) {
        return Failure(WgcProbeStatus::kProtectedWindow, E_ACCESSDENIED, "Refusing a window with display-capture protection.");
    }

    WgcProbeResult result{};
    GetWindowThreadProcessId(window, &result.process_id);
    HRESULT integrity_failure = S_OK;
    result.current_integrity_rid = IntegrityRidForProcess(GetCurrentProcessId(), &integrity_failure);
    if (FAILED(integrity_failure)) {
        return Failure(WgcProbeStatus::kElevatedTarget, integrity_failure, "Could not inspect current process integrity: " + HresultText(integrity_failure));
    }
    result.target_integrity_rid = IntegrityRidForProcess(result.process_id, &integrity_failure);
    if (FAILED(integrity_failure)) {
        return Failure(WgcProbeStatus::kElevatedTarget, integrity_failure, "Could not inspect target process integrity: " + HresultText(integrity_failure));
    }
    if (result.target_integrity_rid > result.current_integrity_rid || result.target_integrity_rid > kIntegrityMedium) {
        result.status = WgcProbeStatus::kElevatedTarget;
        result.hresult = E_ACCESSDENIED;
        result.diagnostic = "Refusing a higher-integrity target window.";
        return result;
    }

    try {
        ProbeApartment apartment;
        const HRESULT apartment_result = apartment.Initialize();
        result.apartment = apartment.apartment();
        result.apartment_initialized_by_probe = apartment.initialized_by_probe();
        if (FAILED(apartment_result)) {
            result.status = WgcProbeStatus::kApartmentInitializationFailed;
            result.hresult = apartment_result;
            result.diagnostic = "Could not initialize or inspect the COM apartment: " + HresultText(apartment_result);
            return result;
        }
        if (!winrt::Windows::Graphics::Capture::GraphicsCaptureSession::IsSupported()) {
            result.status = WgcProbeStatus::kPlatformUnavailable;
            result.hresult = HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
            result.diagnostic = "Windows.Graphics.Capture is not supported by this system (COM apartment=" +
                std::string(WgcProbeApartmentName(result.apartment)) + ", initializedByProbe=" +
                (result.apartment_initialized_by_probe ? "true" : "false") + ").";
            return result;
        }
        const auto interop = winrt::get_activation_factory<
            winrt::Windows::Graphics::Capture::GraphicsCaptureItem,
            IGraphicsCaptureItemInterop>();
        winrt::Windows::Graphics::Capture::GraphicsCaptureItem item{nullptr};
        winrt::check_hresult(interop->CreateForWindow(
            window,
            winrt::guid_of<winrt::Windows::Graphics::Capture::GraphicsCaptureItem>(),
            winrt::put_abi(item)));
        if (!item) {
            result.status = WgcProbeStatus::kCreateItemFailed;
            result.hresult = E_FAIL;
            result.diagnostic = "CreateForWindow returned a null GraphicsCaptureItem (COM apartment=" +
                std::string(WgcProbeApartmentName(result.apartment)) + ").";
            return result;
        }
        result.status = WgcProbeStatus::kSupported;
        result.hresult = S_OK;
        result.diagnostic = "GraphicsCaptureItem creation succeeded (COM apartment=" +
            std::string(WgcProbeApartmentName(result.apartment)) + ", initializedByProbe=" +
            (result.apartment_initialized_by_probe ? "true" : "false") +
            "); no capture session or frames were started.";
        return result;
    } catch (const winrt::hresult_error& error) {
        result.status = error.code() == HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED)
            ? WgcProbeStatus::kPlatformUnavailable : WgcProbeStatus::kCreateItemFailed;
        result.hresult = error.code();
        result.diagnostic = "GraphicsCaptureItem creation failed (COM apartment=" +
            std::string(WgcProbeApartmentName(result.apartment)) + "): " + HresultText(error.code());
        return result;
    }
}

}  // namespace recorder::video
