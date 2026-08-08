#include "wgc_capture_probe.h"

#include <dwmapi.h>
#include <d3d11.h>
#include <roapi.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <windows.graphics.capture.interop.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/base.h>
#include <wrl/client.h>

#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
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
            RoUninitialize();
        }
    }

    WgcProbeApartment apartment() const noexcept { return apartment_; }
    bool initialized_by_probe() const noexcept { return initialized_by_probe_; }

private:
    WgcProbeApartment apartment_ = WgcProbeApartment::kUnknown;
    bool initialized_by_probe_ = false;
};

winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice CreateDirect3DDevice() {
    using Microsoft::WRL::ComPtr;
    ComPtr<ID3D11Device> d3d_device;
    D3D_FEATURE_LEVEL feature_level{};
    const HRESULT created = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr, 0, D3D11_SDK_VERSION, &d3d_device, &feature_level, nullptr);
    winrt::check_hresult(created);
    ComPtr<IDXGIDevice> dxgi_device;
    winrt::check_hresult(d3d_device.As(&dxgi_device));
    ComPtr<IInspectable> inspectable;
    winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(
        dxgi_device.Get(), inspectable.GetAddressOf()));
    return {inspectable.Detach(), winrt::take_ownership_from_abi};
}

struct FrameObservation final {
    std::mutex gate;
    std::condition_variable arrived;
    std::uint64_t frames = 0;
    std::uint32_t first_width = 0;
    std::uint32_t first_height = 0;
    HRESULT callback_failure = S_OK;
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
    case WgcProbeStatus::kDeviceInitializationFailed: return "device-initialization-failed";
    case WgcProbeStatus::kFrameCaptureFailed: return "frame-capture-failed";
    case WgcProbeStatus::kFrameTimeout: return "frame-timeout";
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

WgcProbeResult ProbeWindowGraphicsCaptureFrames(HWND window,
                                                std::uint64_t required_frames,
                                                DWORD timeout_milliseconds) {
    if (required_frames == 0 || timeout_milliseconds == 0) {
        return Failure(WgcProbeStatus::kFrameCaptureFailed, E_INVALIDARG,
                       "Frame probing requires a non-zero frame count and timeout.");
    }

    WgcProbeResult result = ProbeWindowGraphicsCapture(window);
    if (result.status != WgcProbeStatus::kSupported) return result;

    try {
        ProbeApartment apartment;
        const HRESULT apartment_result = apartment.Initialize();
        result.apartment = apartment.apartment();
        result.apartment_initialized_by_probe = apartment.initialized_by_probe();
        if (FAILED(apartment_result)) {
            result.status = WgcProbeStatus::kApartmentInitializationFailed;
            result.hresult = apartment_result;
            result.diagnostic = "Could not initialize the frame-probe COM apartment: " + HresultText(apartment_result);
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
            return Failure(WgcProbeStatus::kCreateItemFailed, E_FAIL,
                           "Frame probe received a null GraphicsCaptureItem.");
        }
        const auto item_size = item.Size();
        if (item_size.Width <= 0 || item_size.Height <= 0) {
            return Failure(WgcProbeStatus::kFrameCaptureFailed, E_INVALIDARG,
                           "Frame probe refused an item with an empty content size.");
        }

        winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice device{nullptr};
        try {
            device = CreateDirect3DDevice();
        } catch (const winrt::hresult_error& error) {
            result.status = WgcProbeStatus::kDeviceInitializationFailed;
            result.hresult = error.code();
            result.diagnostic = "Could not create a D3D11 device for frame probing: " + HresultText(error.code());
            return result;
        }

        auto frame_pool = winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool::CreateFreeThreaded(
            device,
            winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,
            2,
            item_size);
        auto session = frame_pool.CreateCaptureSession(item);
        session.IsCursorCaptureEnabled(false);
        const auto observation = std::make_shared<FrameObservation>();
        auto subscription = frame_pool.FrameArrived(winrt::auto_revoke,
            [observation](const auto& sender, const auto&) {
                try {
                    const auto frame = sender.TryGetNextFrame();
                    if (!frame) return;
                    const auto size = frame.ContentSize();
                    std::lock_guard<std::mutex> lock(observation->gate);
                    if (observation->frames == 0) {
                        observation->first_width = static_cast<std::uint32_t>(size.Width);
                        observation->first_height = static_cast<std::uint32_t>(size.Height);
                    }
                    ++observation->frames;
                    observation->arrived.notify_all();
                } catch (const winrt::hresult_error& error) {
                    std::lock_guard<std::mutex> lock(observation->gate);
                    observation->callback_failure = error.code();
                    observation->arrived.notify_all();
                } catch (...) {
                    std::lock_guard<std::mutex> lock(observation->gate);
                    observation->callback_failure = E_FAIL;
                    observation->arrived.notify_all();
                }
            });
        session.StartCapture();
        {
            std::unique_lock<std::mutex> lock(observation->gate);
            (void)observation->arrived.wait_for(lock, std::chrono::milliseconds(timeout_milliseconds),
                [&] { return observation->frames >= required_frames || FAILED(observation->callback_failure); });
            result.frames_observed = observation->frames;
            result.first_frame_width = observation->first_width;
            result.first_frame_height = observation->first_height;
            if (FAILED(observation->callback_failure)) {
                result.status = WgcProbeStatus::kFrameCaptureFailed;
                result.hresult = observation->callback_failure;
            }
        }
        // Stop accepting callbacks before tearing down the WinRT objects.  The
        // callback owns no retained frame surface, so this cannot leak pixels
        // into a later session.
        subscription.revoke();
        session.Close();
        frame_pool.Close();

        if (result.status == WgcProbeStatus::kFrameCaptureFailed) {
            result.diagnostic = "Exact-HWND frame callback failed: " + HresultText(result.hresult);
            return result;
        }

        if (result.frames_observed < required_frames) {
            result.status = WgcProbeStatus::kFrameTimeout;
            result.hresult = HRESULT_FROM_WIN32(WAIT_TIMEOUT);
            result.diagnostic = "Exact-HWND frame probe timed out after observing " +
                std::to_string(result.frames_observed) + " frame(s); no media was captured.";
            return result;
        }
        result.status = WgcProbeStatus::kSupported;
        result.hresult = S_OK;
        result.diagnostic = "Exact-HWND frame probe observed " + std::to_string(result.frames_observed) +
            " frame(s); no pixels were retained and no media was captured.";
        return result;
    } catch (const winrt::hresult_error& error) {
        result.status = WgcProbeStatus::kFrameCaptureFailed;
        result.hresult = error.code();
        result.diagnostic = "Exact-HWND frame probe failed: " + HresultText(error.code());
        return result;
    } catch (const std::exception& error) {
        result.status = WgcProbeStatus::kFrameCaptureFailed;
        result.hresult = E_FAIL;
        result.diagnostic = "Exact-HWND frame probe failed: " + std::string(error.what());
        return result;
    } catch (...) {
        result.status = WgcProbeStatus::kFrameCaptureFailed;
        result.hresult = E_FAIL;
        result.diagnostic = "Exact-HWND frame probe failed with an unknown exception.";
        return result;
    }
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
