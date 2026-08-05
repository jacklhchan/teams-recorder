#include "wgc_window_capture.h"

#include "wgc_frame_helpers.h"

#include <d3d11.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/base.h>

#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>
#include <utility>
#include <wrl/client.h>

namespace recorder::video {
namespace {

using Microsoft::WRL::ComPtr;
using winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool;
using winrt::Windows::Graphics::Capture::GraphicsCaptureItem;
using winrt::Windows::Graphics::Capture::GraphicsCaptureSession;
using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;

std::string HresultText(HRESULT value) {
    char buffer[16]{};
    std::snprintf(buffer, sizeof(buffer), "0x%08lx", static_cast<unsigned long>(value));
    return buffer;
}

}  // namespace

class WgcWindowCapture::Impl final {
public:
    ~Impl() { (void)Stop(); }

    WgcWindowCaptureStatus Start(HWND window, OwnedBgraFrameCallback callback) {
        if (window == nullptr || !callback) {
            return Fail(WgcWindowCaptureStatus::kInvalidArgument,
                        "A live HWND and frame callback are required.");
        }
        // Do not call the feasibility probe here. It creates a WinRT
        // activation factory on the caller's apartment, while this component
        // owns all WGC activation on its dedicated MTA worker. Keeping one
        // apartment responsible for item/frame/session lifetime avoids a
        // cross-apartment cached-factory lifetime hazard during Stop.
        if (!IsWindow(window) || !IsWindowVisible(window) ||
            (GetWindowLongPtrW(window, GWL_STYLE) & WS_CHILD) != 0) {
            return Fail(WgcWindowCaptureStatus::kUnsupportedTarget,
                        "WGC capture requires a live, visible top-level HWND.");
        }

        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (worker_.joinable() || running_) {
                return FailLocked(WgcWindowCaptureStatus::kInvalidState,
                                  "WGC window capture is already running.");
            }
            stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            started_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (stop_event_ == nullptr || started_event_ == nullptr) {
                CloseEventsLocked();
                return FailLocked(WgcWindowCaptureStatus::kInitializationFailed,
                                  "Creating WGC control events failed.");
            }
            callback_ = std::move(callback);
            stats_ = {};
            error_.clear();
            startup_status_ = WgcWindowCaptureStatus::kInitializationFailed;
        }
        callback_gate_.Open();

        worker_ = std::thread([this, window] { CaptureThread(window); });
        if (WaitForSingleObject(started_event_, 10'000) != WAIT_OBJECT_0) {
            SetEvent(stop_event_);
            worker_.join();
            std::lock_guard<std::mutex> lock(mutex_);
            CloseEventsLocked();
            return FailLocked(WgcWindowCaptureStatus::kInitializationFailed,
                              "Timed out starting WGC window capture.");
        }
        WgcWindowCaptureStatus result = WgcWindowCaptureStatus::kInitializationFailed;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            result = startup_status_;
        }
        if (result != WgcWindowCaptureStatus::kOk) {
            worker_.join();
            std::lock_guard<std::mutex> cleanup_lock(mutex_);
            CloseEventsLocked();
            return result;
        }
        return WgcWindowCaptureStatus::kOk;
    }

    WgcWindowCaptureStatus Stop() {
        HANDLE stop_event = nullptr;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!worker_.joinable()) {
                return running_ ? FailLocked(WgcWindowCaptureStatus::kInvalidState,
                                              "WGC capture worker is unavailable.")
                                : WgcWindowCaptureStatus::kOk;
            }
            running_ = false;
            stop_event = stop_event_;
        }
        if (stop_event != nullptr) {
            SetEvent(stop_event);
        }
        worker_.join();
        std::lock_guard<std::mutex> lock(mutex_);
        callback_ = {};
        CloseEventsLocked();
        return startup_status_ == WgcWindowCaptureStatus::kOk
            ? WgcWindowCaptureStatus::kOk : startup_status_;
    }

    bool is_running() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return running_;
    }

    WgcWindowCaptureStats stats() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return stats_;
    }

    std::string last_error() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return error_;
    }

private:
    void CaptureThread(HWND window) noexcept {
        Direct3D11CaptureFramePool pool{nullptr};
        GraphicsCaptureItem item{nullptr};
        GraphicsCaptureSession session{nullptr};
        winrt::event_token closed{};
        winrt::event_token arrived{};
        bool closed_registered = false;
        bool arrived_registered = false;
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            if (!GraphicsCaptureSession::IsSupported()) {
                SignalStartupFailure(WgcWindowCaptureStatus::kPlatformUnavailable,
                                     "Windows.Graphics.Capture is not supported by this system.");
                return;
            }
            ComPtr<ID3D11Device> d3d_device;
            ComPtr<ID3D11DeviceContext> d3d_context;
            constexpr D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0};
            HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                           D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels,
                                           static_cast<UINT>(sizeof(levels) / sizeof(levels[0])), D3D11_SDK_VERSION,
                                           &d3d_device, nullptr, &d3d_context);
            if (FAILED(hr)) {
                SignalStartupFailure(WgcWindowCaptureStatus::kInitializationFailed,
                                     "Creating the WGC D3D11 device failed: " + HresultText(hr));
                return;
            }
            ComPtr<IDXGIDevice> dxgi_device;
            hr = d3d_device.As(&dxgi_device);
            if (FAILED(hr)) {
                SignalStartupFailure(WgcWindowCaptureStatus::kInitializationFailed,
                                     "Querying the WGC DXGI device failed: " + HresultText(hr));
                return;
            }
            winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice direct3d_device{nullptr};
            winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(
                dxgi_device.Get(), reinterpret_cast<IInspectable**>(winrt::put_abi(direct3d_device))));
            const auto interop = winrt::get_activation_factory<GraphicsCaptureItem,
                IGraphicsCaptureItemInterop>();
            winrt::check_hresult(interop->CreateForWindow(window, winrt::guid_of<GraphicsCaptureItem>(),
                                                          winrt::put_abi(item)));
            const auto initial_size = item.Size();
            if (initial_size.Width <= 0 || initial_size.Height <= 0) {
                SignalStartupFailure(WgcWindowCaptureStatus::kCaptureFailed,
                                     "The WGC target returned an empty content size.");
                return;
            }
            pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
                direct3d_device, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, initial_size);
            session = pool.CreateCaptureSession(item);
            auto size = std::make_shared<BgraFrameSize>(BgraFrameSize{
                initial_size.Width, initial_size.Height});
            closed = item.Closed([this](const auto&, const auto&) {
                CallbackGateLease lease(callback_gate_);
                if (!lease) return;
                SignalRuntimeFailure("The WGC target window closed.");
            });
            closed_registered = true;
            // Keep every callback dependency alive by value. FrameArrived can
            // still be dispatched while Stop is revoking the event token.
            arrived = pool.FrameArrived([this, pool, direct3d_device, d3d_device, d3d_context, size](
                                                const auto&, const auto&) {
                OnFrameArrived(pool, direct3d_device, d3d_device.Get(), d3d_context.Get(), size.get());
            });
            arrived_registered = true;
            session.StartCapture();
            SignalStartupSuccess();
            (void)WaitForSingleObject(stop_event_, INFINITE);
        } catch (const winrt::hresult_error& error) {
            SignalFailure(WgcWindowCaptureStatus::kCaptureFailed,
                          "WGC capture failed: " + HresultText(error.code()));
        } catch (...) {
            SignalFailure(WgcWindowCaptureStatus::kCaptureFailed,
                          "WGC capture failed unexpectedly.");
        }

        // Event tokens must be revoked before the gate is closed.  The gate
        // then waits for every callback which raced revocation, including
        // GraphicsCaptureItem::Closed, before any captured owner is released.
        try {
            if (arrived_registered && pool) pool.FrameArrived(arrived);
        } catch (...) {
            SignalFailure(WgcWindowCaptureStatus::kCaptureFailed,
                          "Revoking the WGC FrameArrived handler failed.");
        }
        try {
            if (closed_registered && item) item.Closed(closed);
        } catch (...) {
            SignalFailure(WgcWindowCaptureStatus::kCaptureFailed,
                          "Revoking the WGC Closed handler failed.");
        }
        callback_gate_.CloseAndWait();
        try {
            if (session) session.Close();
            if (pool) pool.Close();
        } catch (...) {
            SignalFailure(WgcWindowCaptureStatus::kCaptureFailed,
                          "Closing the WGC capture session failed.");
        }
    }

    void OnFrameArrived(Direct3D11CaptureFramePool const& pool,
                        winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice const& direct3d_device,
                        ID3D11Device* device,
                        ID3D11DeviceContext* context, BgraFrameSize* size) noexcept {
        CallbackGateLease lease(callback_gate_);
        if (!lease) {
            return;
        }
        try {
            if (device == nullptr || context == nullptr || size == nullptr) {
                return;
            }
            auto frame = pool.TryGetNextFrame();
            if (!frame) {
                return;
            }
            {
                std::lock_guard<std::mutex> lock(mutex_);
                ++stats_.received_frames;
            }
            const auto content = frame.ContentSize();
            const BgraFrameSize incoming{content.Width, content.Height};
            if (FramePoolNeedsRecreate(*size, incoming)) {
                if (!incoming.IsValid()) {
                    return;
                }
                pool.Recreate(direct3d_device,
                              DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, content);
                *size = incoming;
                std::lock_guard<std::mutex> lock(mutex_);
                ++stats_.frame_pool_recreates;
                return;
            }
            ComPtr<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess> access;
            winrt::check_hresult(winrt::get_unknown(frame.Surface())->QueryInterface(
                IID_PPV_ARGS(&access)));
            ComPtr<ID3D11Texture2D> source;
            winrt::check_hresult(access->GetInterface(IID_PPV_ARGS(&source)));
            D3D11_TEXTURE2D_DESC description{};
            source->GetDesc(&description);
            description.BindFlags = 0;
            description.MiscFlags = 0;
            description.Usage = D3D11_USAGE_STAGING;
            description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            ComPtr<ID3D11Texture2D> staging;
            winrt::check_hresult(device->CreateTexture2D(&description, nullptr, &staging));
            context->CopyResource(staging.Get(), source.Get());
            D3D11_MAPPED_SUBRESOURCE mapped{};
            winrt::check_hresult(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped));
            OwnedBgraFrame owned;
            owned.width = static_cast<std::int32_t>(description.Width);
            owned.height = static_cast<std::int32_t>(description.Height);
            owned.stride_bytes = owned.width * 4;
            owned.system_relative_time_100ns = frame.SystemRelativeTime().count();
            owned.pixels.resize(static_cast<std::size_t>(owned.stride_bytes) *
                                static_cast<std::size_t>(owned.height));
            for (std::int32_t row = 0; row < owned.height; ++row) {
                std::memcpy(owned.pixels.data() + static_cast<std::size_t>(row) * owned.stride_bytes,
                            static_cast<const std::uint8_t*>(mapped.pData) +
                                static_cast<std::size_t>(row) * mapped.RowPitch,
                            static_cast<std::size_t>(owned.stride_bytes));
            }
            context->Unmap(staging.Get(), 0);
            OwnedBgraFrameCallback callback;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (!running_ || !callback_) {
                    ++stats_.dropped_frames;
                    return;
                }
                callback = callback_;
            }
            callback(std::move(owned));
            std::lock_guard<std::mutex> lock(mutex_);
            ++stats_.delivered_frames;
        } catch (const winrt::hresult_error& error) {
            SignalRuntimeFailure("Copying an owned WGC frame failed: " + HresultText(error.code()));
        } catch (...) {
            SignalRuntimeFailure("Copying an owned WGC frame failed unexpectedly.");
        }
    }

    void SignalStartupSuccess() noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        startup_status_ = WgcWindowCaptureStatus::kOk;
        running_ = true;
        SetEvent(started_event_);
    }

    void SignalStartupFailure(WgcWindowCaptureStatus status, std::string error) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        startup_status_ = status;
        error_ = std::move(error);
        if (started_event_ != nullptr) {
            SetEvent(started_event_);
        }
    }

    void SignalFailure(WgcWindowCaptureStatus status, std::string error) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        if (startup_status_ != WgcWindowCaptureStatus::kOk) {
            startup_status_ = status;
        } else {
            startup_status_ = status;
            running_ = false;
        }
        if (error_.empty()) {
            error_ = std::move(error);
        }
        if (started_event_ != nullptr) {
            SetEvent(started_event_);
        }
        if (stop_event_ != nullptr) {
            SetEvent(stop_event_);
        }
    }

    void SignalRuntimeFailure(std::string error) noexcept {
        SignalFailure(WgcWindowCaptureStatus::kCaptureFailed, std::move(error));
    }

    WgcWindowCaptureStatus Fail(WgcWindowCaptureStatus status, std::string error) {
        std::lock_guard<std::mutex> lock(mutex_);
        return FailLocked(status, std::move(error));
    }

    WgcWindowCaptureStatus FailLocked(WgcWindowCaptureStatus status, std::string error) {
        error_ = std::move(error);
        return status;
    }

    void CloseEventsLocked() noexcept {
        if (started_event_ != nullptr) {
            CloseHandle(started_event_);
            started_event_ = nullptr;
        }
        if (stop_event_ != nullptr) {
            CloseHandle(stop_event_);
            stop_event_ = nullptr;
        }
    }

    mutable std::mutex mutex_;
    CallbackGate callback_gate_;
    std::thread worker_;
    HANDLE stop_event_ = nullptr;
    HANDLE started_event_ = nullptr;
    OwnedBgraFrameCallback callback_;
    WgcWindowCaptureStats stats_{};
    WgcWindowCaptureStatus startup_status_ = WgcWindowCaptureStatus::kInvalidState;
    std::string error_;
    bool running_ = false;
};

WgcWindowCapture::WgcWindowCapture() : impl_(std::make_unique<Impl>()) {}
WgcWindowCapture::~WgcWindowCapture() = default;
WgcWindowCaptureStatus WgcWindowCapture::Start(HWND window, OwnedBgraFrameCallback callback) {
    return impl_->Start(window, std::move(callback));
}
WgcWindowCaptureStatus WgcWindowCapture::Stop() { return impl_->Stop(); }
bool WgcWindowCapture::is_running() const { return impl_->is_running(); }
WgcWindowCaptureStats WgcWindowCapture::stats() const { return impl_->stats(); }
std::string WgcWindowCapture::last_error() const { return impl_->last_error(); }

const char* WgcWindowCaptureStatusName(WgcWindowCaptureStatus status) noexcept {
    switch (status) {
    case WgcWindowCaptureStatus::kOk: return "ok";
    case WgcWindowCaptureStatus::kInvalidArgument: return "invalid-argument";
    case WgcWindowCaptureStatus::kUnsupportedTarget: return "unsupported-target";
    case WgcWindowCaptureStatus::kPlatformUnavailable: return "platform-unavailable";
    case WgcWindowCaptureStatus::kInitializationFailed: return "initialization-failed";
    case WgcWindowCaptureStatus::kCaptureFailed: return "capture-failed";
    case WgcWindowCaptureStatus::kInvalidState: return "invalid-state";
    }
    return "unknown";
}

}  // namespace recorder::video
