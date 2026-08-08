#include "wgc_window_capture_session.h"

#include "bgra_to_nv12.h"
#include "wgc_capture_probe.h"

#include <d3d11.h>
#include <roapi.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/base.h>
#include <wrl/client.h>

#include <chrono>
#include <condition_variable>
#include <deque>
#include <limits>
#include <mutex>
#include <thread>
#include <utility>

namespace recorder::video {
namespace {

using Microsoft::WRL::ComPtr;

constexpr std::uint32_t kMaximumCanvasWidth = 1'920;
constexpr std::uint32_t kMaximumCanvasHeight = 1'080;
constexpr std::size_t kMaximumQueuedFrames = 16;

WgcCaptureResult Result(WgcCaptureError error, HRESULT hresult,
                        const char* detail) {
    WgcCaptureResult result{};
    result.error = error;
    result.hresult = hresult;
    result.detail = detail;
    return result;
}

bool GetProcessCreationTime(DWORD process_id, std::uint64_t* creation_time,
                            HRESULT* failure) noexcept {
    if (creation_time == nullptr || failure == nullptr || process_id == 0) {
        if (failure != nullptr) *failure = E_INVALIDARG;
        return false;
    }
    const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
    if (process == nullptr) {
        *failure = HRESULT_FROM_WIN32(GetLastError());
        return false;
    }
    FILETIME created{};
    FILETIME exited{};
    FILETIME kernel{};
    FILETIME user{};
    const BOOL got_times = GetProcessTimes(process, &created, &exited, &kernel, &user);
    const DWORD last_error = got_times ? ERROR_SUCCESS : GetLastError();
    CloseHandle(process);
    if (!got_times) {
        *failure = HRESULT_FROM_WIN32(last_error);
        return false;
    }
    *creation_time = (static_cast<std::uint64_t>(created.dwHighDateTime) << 32U) |
                     static_cast<std::uint64_t>(created.dwLowDateTime);
    *failure = S_OK;
    return *creation_time != 0;
}

bool HasMatchingIdentity(const WgcWindowTargetIdentity& target,
                         HRESULT* failure) noexcept {
    if (target.window == nullptr || target.process_id == 0 ||
        target.process_creation_time_100ns == 0 || !IsWindow(target.window)) {
        if (failure != nullptr) *failure = E_INVALIDARG;
        return false;
    }
    DWORD process_id = 0;
    GetWindowThreadProcessId(target.window, &process_id);
    if (process_id != target.process_id) {
        if (failure != nullptr) *failure = HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);
        return false;
    }
    std::uint64_t creation_time = 0;
    HRESULT creation_failure = S_OK;
    if (!GetProcessCreationTime(process_id, &creation_time, &creation_failure) ||
        creation_time != target.process_creation_time_100ns) {
        if (failure != nullptr) *failure = FAILED(creation_failure)
            ? creation_failure : HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);
        return false;
    }
    if (failure != nullptr) *failure = S_OK;
    return true;
}

bool HasValidConfig(const WgcWindowCaptureConfig& config) noexcept {
    return config.target.window != nullptr && config.target.process_id != 0 &&
        config.target.process_creation_time_100ns != 0 && config.canvas_width >= 2 &&
        config.canvas_height >= 2 && config.canvas_width <= kMaximumCanvasWidth &&
        config.canvas_height <= kMaximumCanvasHeight && (config.canvas_width % 2U) == 0 &&
        (config.canvas_height % 2U) == 0 && config.max_queued_frames > 0 &&
        config.max_queued_frames <= kMaximumQueuedFrames;
}

WgcCaptureError ProbeError(const WgcProbeStatus status) noexcept {
    switch (status) {
    case WgcProbeStatus::kPlatformUnavailable:
        return WgcCaptureError::kPlatformUnavailable;
    case WgcProbeStatus::kCreateItemFailed:
        return WgcCaptureError::kItemCreationFailed;
    case WgcProbeStatus::kDeviceInitializationFailed:
        return WgcCaptureError::kDeviceInitializationFailed;
    case WgcProbeStatus::kInvalidWindow:
    case WgcProbeStatus::kHiddenWindow:
    case WgcProbeStatus::kChildWindow:
    case WgcProbeStatus::kCloakedWindow:
    case WgcProbeStatus::kProtectedWindow:
    case WgcProbeStatus::kElevatedTarget:
    case WgcProbeStatus::kApartmentInitializationFailed:
    case WgcProbeStatus::kFrameCaptureFailed:
    case WgcProbeStatus::kFrameTimeout:
        return WgcCaptureError::kTargetRejected;
    case WgcProbeStatus::kSupported:
        return WgcCaptureError::kOk;
    }
    return WgcCaptureError::kInternalFailure;
}

struct D3dBundle {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice winrt_device{nullptr};
};

HRESULT CreateD3dBundle(D3dBundle* bundle) {
    if (bundle == nullptr) return E_INVALIDARG;
    D3D_FEATURE_LEVEL feature_level{};
    HRESULT hr = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr, 0, D3D11_SDK_VERSION, &bundle->device, &feature_level, &bundle->context);
    if (FAILED(hr)) return hr;
    ComPtr<IDXGIDevice> dxgi_device;
    hr = bundle->device.As(&dxgi_device);
    if (FAILED(hr)) return hr;
    ComPtr<IInspectable> inspectable;
    hr = CreateDirect3D11DeviceFromDXGIDevice(dxgi_device.Get(), inspectable.GetAddressOf());
    if (FAILED(hr)) return hr;
    bundle->winrt_device = {inspectable.Detach(), winrt::take_ownership_from_abi};
    return S_OK;
}

struct SharedState final {
    explicit SharedState(WgcWindowCaptureConfig requested_config)
        : config(std::move(requested_config)) { }

    mutable std::mutex mutex;
    std::condition_variable changed;
    std::condition_variable callbacks_idle;
    WgcWindowCaptureConfig config;
    std::deque<WgcNv12Frame> queue;
    WgcCaptureStats stats{};
    WgcWindowCaptureState state = WgcWindowCaptureState::kStarting;
    WgcCaptureResult result = Result(WgcCaptureError::kInvalidState, E_PENDING,
                                     "WGC capture is starting.");
    bool startup_complete = false;
    bool stop_requested = false;
    bool accepting_callbacks = false;
    std::uint32_t active_callbacks = 0;
};

struct CaptureRuntime final {
    D3dBundle d3d;
    winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool frame_pool{nullptr};
    ComPtr<ID3D11Texture2D> staging_texture;
    D3D11_TEXTURE2D_DESC staging_description{};
    std::mutex conversion_mutex;
};

class ScopedRoApartment final {
public:
    HRESULT Initialize() noexcept {
        const HRESULT result = RoInitialize(RO_INIT_MULTITHREADED);
        if (SUCCEEDED(result)) owns_apartment_ = true;
        return result;
    }
    ~ScopedRoApartment() {
        if (owns_apartment_) RoUninitialize();
    }

private:
    bool owns_apartment_ = false;
};

bool EnterCallback(const std::shared_ptr<SharedState>& state) noexcept {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (!state->accepting_callbacks || state->stop_requested ||
        state->state != WgcWindowCaptureState::kRunning) {
        return false;
    }
    ++state->active_callbacks;
    return true;
}

void ExitCallback(const std::shared_ptr<SharedState>& state) noexcept {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->active_callbacks > 0) --state->active_callbacks;
    if (state->active_callbacks == 0) state->callbacks_idle.notify_all();
}

class CallbackGuard final {
public:
    explicit CallbackGuard(std::shared_ptr<SharedState> state) noexcept
        : state_(std::move(state)) { }
    ~CallbackGuard() { ExitCallback(state_); }
    CallbackGuard(const CallbackGuard&) = delete;
    CallbackGuard& operator=(const CallbackGuard&) = delete;

private:
    std::shared_ptr<SharedState> state_;
};

void SetFailure(const std::shared_ptr<SharedState>& state, WgcCaptureError error,
                HRESULT hresult, const char* detail) noexcept {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->state == WgcWindowCaptureState::kFailed ||
        state->state == WgcWindowCaptureState::kStopped) {
        return;
    }
    state->result = Result(error, hresult, detail);
    state->state = WgcWindowCaptureState::kFailed;
    state->stop_requested = true;
    state->changed.notify_all();
}

void CompleteStartup(const std::shared_ptr<SharedState>& state, WgcCaptureResult result,
                     WgcWindowCaptureState session_state) noexcept {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->result = std::move(result);
    state->state = session_state;
    state->startup_complete = true;
    if (session_state == WgcWindowCaptureState::kFailed) state->stop_requested = true;
    state->changed.notify_all();
}

void DisableCallbacks(const std::shared_ptr<SharedState>& state) noexcept {
    std::unique_lock<std::mutex> lock(state->mutex);
    state->accepting_callbacks = false;
    state->callbacks_idle.wait(lock, [&] { return state->active_callbacks == 0; });
}

bool QueueHasCapacity(const std::shared_ptr<SharedState>& state) noexcept {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->queue.size() >= state->config.max_queued_frames) {
        ++state->stats.frames_dropped_queue_full;
        return false;
    }
    return true;
}

bool EnsureStagingTexture(CaptureRuntime* runtime,
                          const D3D11_TEXTURE2D_DESC& source_description) noexcept {
    if (runtime == nullptr || source_description.Width == 0 || source_description.Height == 0 ||
        source_description.MipLevels != 1 || source_description.ArraySize != 1 || source_description.SampleDesc.Count != 1 ||
        source_description.SampleDesc.Quality != 0 || source_description.Format != DXGI_FORMAT_B8G8R8A8_UNORM) {
        return false;
    }
    const bool current = runtime->staging_texture != nullptr &&
        runtime->staging_description.Width == source_description.Width &&
        runtime->staging_description.Height == source_description.Height &&
        runtime->staging_description.Format == source_description.Format;
    if (current) return true;
    D3D11_TEXTURE2D_DESC staging = source_description;
    staging.MipLevels = 1;
    staging.ArraySize = 1;
    staging.Usage = D3D11_USAGE_STAGING;
    staging.BindFlags = 0;
    staging.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    staging.MiscFlags = 0;
    ComPtr<ID3D11Texture2D> texture;
    const HRESULT result = runtime->d3d.device->CreateTexture2D(&staging, nullptr, &texture);
    if (FAILED(result)) return false;
    runtime->staging_texture = std::move(texture);
    runtime->staging_description = source_description;
    return true;
}

bool CopyAndConvertFrame(const std::shared_ptr<SharedState>& state,
                         const std::shared_ptr<CaptureRuntime>& runtime,
                         const winrt::Windows::Graphics::Capture::Direct3D11CaptureFrame& frame,
                         WgcNv12Frame* output, WgcCaptureError* failure,
                         HRESULT* hresult) noexcept {
    if (output == nullptr || failure == nullptr || hresult == nullptr) return false;
    *failure = WgcCaptureError::kFrameCopyFailed;
    *hresult = E_FAIL;
    const auto size = frame.ContentSize();
    if (size.Width <= 0 || size.Height <= 0) {
        *hresult = E_INVALIDARG;
        return false;
    }
    const auto source_width = static_cast<std::uint32_t>(size.Width);
    const auto source_height = static_cast<std::uint32_t>(size.Height);
    const auto relative_time = frame.SystemRelativeTime().count();
    if (relative_time < 0) {
        *hresult = E_INVALIDARG;
        return false;
    }

    try {
        std::lock_guard<std::mutex> conversion_lock(runtime->conversion_mutex);
        const auto surface_access = frame.Surface().as<
            Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
        ComPtr<ID3D11Texture2D> source_texture;
        const HRESULT texture_result = surface_access->GetInterface(
            __uuidof(ID3D11Texture2D),
            reinterpret_cast<void**>(source_texture.GetAddressOf()));
        if (FAILED(texture_result) || !source_texture) {
            *hresult = FAILED(texture_result) ? texture_result : E_FAIL;
            return false;
        }
        D3D11_TEXTURE2D_DESC source_description{};
        source_texture->GetDesc(&source_description);
        if (source_description.Width < source_width || source_description.Height < source_height ||
            !EnsureStagingTexture(runtime.get(), source_description)) {
            *hresult = E_INVALIDARG;
            return false;
        }
        runtime->d3d.context->CopyResource(runtime->staging_texture.Get(), source_texture.Get());
        D3D11_MAPPED_SUBRESOURCE mapped{};
        const HRESULT map_result = runtime->d3d.context->Map(
            runtime->staging_texture.Get(), 0, D3D11_MAP_READ, 0, &mapped);
        if (FAILED(map_result) || mapped.pData == nullptr ||
            mapped.RowPitch < static_cast<std::size_t>(source_width) * 4U ||
            mapped.RowPitch > std::numeric_limits<std::uint32_t>::max()) {
            if (SUCCEEDED(map_result)) runtime->d3d.context->Unmap(runtime->staging_texture.Get(), 0);
            *hresult = FAILED(map_result) ? map_result : E_FAIL;
            return false;
        }
        const bool converted = ConvertBgraToNv12Letterboxed(
            static_cast<const std::uint8_t*>(mapped.pData), static_cast<std::uint32_t>(mapped.RowPitch),
            source_width, source_height, state->config.canvas_width, state->config.canvas_height,
            &output->bytes);
        runtime->d3d.context->Unmap(runtime->staging_texture.Get(), 0);
        if (!converted) {
            *failure = WgcCaptureError::kFrameConversionFailed;
            *hresult = E_FAIL;
            return false;
        }
        output->width = state->config.canvas_width;
        output->height = state->config.canvas_height;
        output->stride = state->config.canvas_width;
        output->system_relative_time_100ns = static_cast<std::uint64_t>(relative_time);
        *failure = WgcCaptureError::kOk;
        *hresult = S_OK;
        return true;
    } catch (const winrt::hresult_error& error) {
        *hresult = error.code();
    } catch (...) {
        *hresult = E_FAIL;
    }
    return false;
}

void ProcessFrame(const std::shared_ptr<SharedState>& state,
                  const std::shared_ptr<CaptureRuntime>& runtime,
                  const winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool& sender) noexcept {
    if (!EnterCallback(state)) return;
    CallbackGuard guard(state);
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        ++state->stats.frames_arrived;
    }
    HRESULT identity_failure = S_OK;
    if (!HasMatchingIdentity(state->config.target, &identity_failure)) {
        SetFailure(state, WgcCaptureError::kTargetLost, identity_failure,
                   "The selected capture window is no longer the validated target.");
        return;
    }
    try {
        const auto frame = sender.TryGetNextFrame();
        if (!frame) {
            std::lock_guard<std::mutex> lock(state->mutex);
            ++state->stats.frames_dropped_invalid;
            return;
        }
        // Always consume the frame-pool notification before deciding whether
        // to drop it. Returning while the pool still owns a pending frame can
        // stall delivery under sustained encoder back-pressure.
        if (!QueueHasCapacity(state)) return;
        const auto content_size = frame.ContentSize();
        if (content_size.Width <= 0 || content_size.Height <= 0) {
            std::lock_guard<std::mutex> lock(state->mutex);
            ++state->stats.frames_dropped_invalid;
            return;
        }
        const auto source_width = static_cast<std::uint32_t>(content_size.Width);
        const auto source_height = static_cast<std::uint32_t>(content_size.Height);
        bool recreate_pool = false;
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            recreate_pool = state->stats.latest_source_width != source_width ||
                state->stats.latest_source_height != source_height;
        }
        WgcNv12Frame converted{};
        WgcCaptureError conversion_failure = WgcCaptureError::kFrameCopyFailed;
        HRESULT conversion_hresult = E_FAIL;
        if (!CopyAndConvertFrame(state, runtime, frame, &converted, &conversion_failure,
                                 &conversion_hresult)) {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (conversion_failure == WgcCaptureError::kFrameConversionFailed) {
                ++state->stats.frames_dropped_conversion_failure;
            } else {
                ++state->stats.frames_dropped_copy_failure;
            }
            return;
        }
        // Recreate only after the current frame has been copied. A frame pool
        // resize can invalidate its backing surface; converting first avoids
        // reading an undefined/reused surface and keeps resize fail-closed.
        if (recreate_pool) {
            sender.Recreate(runtime->d3d.winrt_device,
                winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,
                2, content_size);
        }
        std::lock_guard<std::mutex> lock(state->mutex);
        state->stats.latest_source_width = source_width;
        state->stats.latest_source_height = source_height;
        if (recreate_pool) ++state->stats.frame_pool_recreations;
        if (state->stop_requested || state->state != WgcWindowCaptureState::kRunning) return;
        if (state->queue.size() >= state->config.max_queued_frames) {
            ++state->stats.frames_dropped_queue_full;
            return;
        }
        state->queue.emplace_back(std::move(converted));
        ++state->stats.frames_enqueued;
        state->changed.notify_all();
    } catch (const winrt::hresult_error& error) {
        SetFailure(state, WgcCaptureError::kFramePoolCreationFailed, error.code(),
                   "The exact-window WGC frame callback failed.");
    } catch (...) {
        SetFailure(state, WgcCaptureError::kInternalFailure, E_FAIL,
                   "The exact-window WGC frame callback failed.");
    }
}

void WorkerMain(const std::shared_ptr<SharedState>& state) noexcept {
    ScopedRoApartment apartment;
    const HRESULT apartment_result = apartment.Initialize();
    if (FAILED(apartment_result)) {
        CompleteStartup(state, Result(WgcCaptureError::kInternalFailure, apartment_result,
                                      "Could not initialize the WGC worker apartment."),
                        WgcWindowCaptureState::kFailed);
        return;
    }
    HRESULT identity_failure = S_OK;
    if (!HasMatchingIdentity(state->config.target, &identity_failure)) {
        CompleteStartup(state, Result(WgcCaptureError::kTargetIdentityMismatch, identity_failure,
                                      "The selected capture target no longer matches its validated identity."),
                        WgcWindowCaptureState::kFailed);
        return;
    }
    const WgcProbeResult probe = ProbeWindowGraphicsCapture(state->config.target.window);
    if (probe.status != WgcProbeStatus::kSupported) {
        CompleteStartup(state, Result(ProbeError(probe.status), probe.hresult,
                                      "The selected capture target was rejected before WGC started."),
                        WgcWindowCaptureState::kFailed);
        return;
    }
    if (!HasMatchingIdentity(state->config.target, &identity_failure)) {
        CompleteStartup(state, Result(WgcCaptureError::kTargetIdentityMismatch, identity_failure,
                                      "The selected capture target changed before WGC started."),
                        WgcWindowCaptureState::kFailed);
        return;
    }

    try {
        const auto interop = winrt::get_activation_factory<
            winrt::Windows::Graphics::Capture::GraphicsCaptureItem,
            IGraphicsCaptureItemInterop>();
        winrt::Windows::Graphics::Capture::GraphicsCaptureItem item{nullptr};
        winrt::check_hresult(interop->CreateForWindow(
            state->config.target.window,
            winrt::guid_of<winrt::Windows::Graphics::Capture::GraphicsCaptureItem>(),
            winrt::put_abi(item)));
        if (!item) {
            CompleteStartup(state, Result(WgcCaptureError::kItemCreationFailed, E_FAIL,
                                          "WGC did not return an exact-window capture item."),
                            WgcWindowCaptureState::kFailed);
            return;
        }
        const auto item_size = item.Size();
        if (item_size.Width <= 0 || item_size.Height <= 0) {
            CompleteStartup(state, Result(WgcCaptureError::kItemCreationFailed, E_INVALIDARG,
                                          "The exact-window capture item has no content size."),
                            WgcWindowCaptureState::kFailed);
            return;
        }
        auto runtime = std::make_shared<CaptureRuntime>();
        const HRESULT d3d_result = CreateD3dBundle(&runtime->d3d);
        if (FAILED(d3d_result)) {
            CompleteStartup(state, Result(WgcCaptureError::kDeviceInitializationFailed, d3d_result,
                                          "Could not initialize the exact-window WGC device."),
                            WgcWindowCaptureState::kFailed);
            return;
        }
        runtime->frame_pool = winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool::CreateFreeThreaded(
            runtime->d3d.winrt_device,
            winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,
            2, item_size);
        auto session = runtime->frame_pool.CreateCaptureSession(item);
        session.IsCursorCaptureEnabled(false);
        auto item_closed = item.Closed(winrt::auto_revoke,
            [state](const auto&, const auto&) noexcept {
                SetFailure(state, WgcCaptureError::kTargetLost,
                           HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE),
                           "The selected capture window was closed.");
            });
        auto subscription = runtime->frame_pool.FrameArrived(winrt::auto_revoke,
            [state, runtime](const auto& sender, const auto&) noexcept {
                ProcessFrame(state, runtime, sender);
            });
        // StartCapture is intentionally reached before reporting success.  The
        // callback gate stays closed during this tiny interval, so an early
        // frame is dropped rather than racing with startup state.
        session.StartCapture();
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->stats.latest_source_width = static_cast<std::uint32_t>(item_size.Width);
            state->stats.latest_source_height = static_cast<std::uint32_t>(item_size.Height);
            if (state->stop_requested) {
                state->startup_complete = true;
                state->state = WgcWindowCaptureState::kStopped;
                state->result = Result(WgcCaptureError::kOk, S_OK,
                                       "Exact-window WGC capture stopped before startup completed.");
                state->changed.notify_all();
            } else {
                state->accepting_callbacks = true;
                state->state = WgcWindowCaptureState::kRunning;
                state->result = Result(WgcCaptureError::kOk, S_OK,
                                       "Exact-window WGC capture is running.");
                state->startup_complete = true;
                state->changed.notify_all();
            }
        }
        {
            std::unique_lock<std::mutex> lock(state->mutex);
            state->changed.wait(lock, [&] { return state->stop_requested; });
            if (state->state == WgcWindowCaptureState::kRunning) {
                state->state = WgcWindowCaptureState::kStopping;
            }
        }
        DisableCallbacks(state);
        subscription.revoke();
        item_closed.revoke();
        session.Close();
        runtime->frame_pool.Close();
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->state != WgcWindowCaptureState::kFailed) {
                state->state = WgcWindowCaptureState::kStopped;
                state->result = Result(WgcCaptureError::kOk, S_OK,
                                       "Exact-window WGC capture stopped.");
            }
            state->changed.notify_all();
        }
    } catch (const winrt::hresult_error& error) {
        CompleteStartup(state, Result(WgcCaptureError::kFramePoolCreationFailed, error.code(),
                                      "Could not initialize the exact-window WGC frame pool."),
                        WgcWindowCaptureState::kFailed);
    } catch (...) {
        CompleteStartup(state, Result(WgcCaptureError::kInternalFailure, E_FAIL,
                                      "Could not initialize the exact-window WGC session."),
                        WgcWindowCaptureState::kFailed);
    }
}

}  // namespace

const char* WgcCaptureErrorName(WgcCaptureError error) noexcept {
    switch (error) {
    case WgcCaptureError::kOk: return "ok";
    case WgcCaptureError::kInvalidArgument: return "invalid-argument";
    case WgcCaptureError::kInvalidState: return "invalid-state";
    case WgcCaptureError::kTargetNotLive: return "target-not-live";
    case WgcCaptureError::kTargetIdentityMismatch: return "target-identity-mismatch";
    case WgcCaptureError::kTargetRejected: return "target-rejected";
    case WgcCaptureError::kPlatformUnavailable: return "platform-unavailable";
    case WgcCaptureError::kItemCreationFailed: return "item-creation-failed";
    case WgcCaptureError::kDeviceInitializationFailed: return "device-initialization-failed";
    case WgcCaptureError::kFramePoolCreationFailed: return "frame-pool-creation-failed";
    case WgcCaptureError::kTargetLost: return "target-lost";
    case WgcCaptureError::kFrameCopyFailed: return "frame-copy-failed";
    case WgcCaptureError::kFrameConversionFailed: return "frame-conversion-failed";
    case WgcCaptureError::kInternalFailure: return "internal-failure";
    }
    return "unknown";
}

WgcCaptureResult BuildWgcWindowTargetIdentity(HWND window,
                                               WgcWindowTargetIdentity* target) {
    if (target == nullptr || window == nullptr || !IsWindow(window)) {
        return Result(WgcCaptureError::kTargetNotLive, E_INVALIDARG,
                      "A live top-level window is required for WGC capture.");
    }
    DWORD process_id = 0;
    GetWindowThreadProcessId(window, &process_id);
    if (process_id == 0) {
        return Result(WgcCaptureError::kTargetNotLive, HRESULT_FROM_WIN32(GetLastError()),
                      "The selected WGC window has no owning process.");
    }
    std::uint64_t creation_time = 0;
    HRESULT failure = S_OK;
    if (!GetProcessCreationTime(process_id, &creation_time, &failure)) {
        return Result(WgcCaptureError::kTargetRejected, failure,
                      "Could not validate the selected WGC target identity.");
    }
    target->window = window;
    target->process_id = process_id;
    target->process_creation_time_100ns = creation_time;
    return Result(WgcCaptureError::kOk, S_OK, "Exact-window WGC target identity is valid.");
}

class WgcWindowCaptureSession::Impl final {
public:
    ~Impl() { Stop(); }

    WgcCaptureResult Start(const WgcWindowCaptureConfig& config) {
        if (!HasValidConfig(config)) {
            return Result(WgcCaptureError::kInvalidArgument, E_INVALIDARG,
                          "WGC capture requires an even supported canvas, bounded queue, and exact target identity.");
        }
        std::unique_lock<std::mutex> lifecycle_lock(lifecycle_mutex_);
        if (worker_.joinable()) {
            return Result(WgcCaptureError::kInvalidState, E_UNEXPECTED,
                          "Stop the previous WGC session before starting another one.");
        }
        HRESULT identity_failure = S_OK;
        if (!HasMatchingIdentity(config.target, &identity_failure)) {
            return Result(WgcCaptureError::kTargetIdentityMismatch, identity_failure,
                          "The selected WGC target no longer matches its validated identity.");
        }
        auto state = std::make_shared<SharedState>(config);
        state_ = state;
        try {
            worker_ = std::thread([state] { WorkerMain(state); });
        } catch (...) {
            state_.reset();
            return Result(WgcCaptureError::kInternalFailure, E_FAIL,
                          "Could not create the WGC session worker.");
        }
        {
            std::unique_lock<std::mutex> state_lock(state->mutex);
            state->changed.wait(state_lock, [&] { return state->startup_complete; });
        }
        WgcCaptureResult result;
        {
            std::lock_guard<std::mutex> state_lock(state->mutex);
            result = state->result;
        }
        if (!result.succeeded()) {
            std::thread completed_worker = std::move(worker_);
            lifecycle_lock.unlock();
            if (completed_worker.joinable()) completed_worker.join();
            return result;
        }
        return result;
    }

    void Stop() noexcept {
        std::thread worker;
        std::shared_ptr<SharedState> state;
        {
            std::lock_guard<std::mutex> lifecycle_lock(lifecycle_mutex_);
            state = state_;
            if (state) {
                std::lock_guard<std::mutex> state_lock(state->mutex);
                state->stop_requested = true;
                state->changed.notify_all();
            }
            worker = std::move(worker_);
        }
        if (worker.joinable()) worker.join();
    }

    bool TryPopFrame(WgcNv12Frame* frame) {
        if (frame == nullptr) return false;
        const auto state = StateSnapshot();
        if (!state) return false;
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->queue.empty()) return false;
        *frame = std::move(state->queue.front());
        state->queue.pop_front();
        ++state->stats.frames_dequeued;
        return true;
    }

    bool WaitPopFrame(WgcNv12Frame* frame, DWORD timeout_milliseconds) {
        if (frame == nullptr) return false;
        const auto state = StateSnapshot();
        if (!state) return false;
        std::unique_lock<std::mutex> lock(state->mutex);
        const auto ready = [&] {
            return !state->queue.empty() || state->state == WgcWindowCaptureState::kStopped ||
                state->state == WgcWindowCaptureState::kFailed;
        };
        if (!ready()) {
            if (timeout_milliseconds == INFINITE) {
                state->changed.wait(lock, ready);
            } else if (!state->changed.wait_for(lock, std::chrono::milliseconds(timeout_milliseconds), ready)) {
                return false;
            }
        }
        if (state->queue.empty()) return false;
        *frame = std::move(state->queue.front());
        state->queue.pop_front();
        ++state->stats.frames_dequeued;
        return true;
    }

    bool IsRunning() const noexcept { return State() == WgcWindowCaptureState::kRunning; }

    WgcWindowCaptureState State() const noexcept {
        const auto state = StateSnapshot();
        if (!state) return WgcWindowCaptureState::kIdle;
        std::lock_guard<std::mutex> lock(state->mutex);
        return state->state;
    }

    WgcCaptureStats Stats() const noexcept {
        const auto state = StateSnapshot();
        if (!state) return {};
        std::lock_guard<std::mutex> lock(state->mutex);
        return state->stats;
    }

    WgcCaptureResult LastResult() const {
        const auto state = StateSnapshot();
        if (!state) return Result(WgcCaptureError::kInvalidState, E_UNEXPECTED,
                                  "WGC capture has not been started.");
        std::lock_guard<std::mutex> lock(state->mutex);
        return state->result;
    }

private:
    std::shared_ptr<SharedState> StateSnapshot() const noexcept {
        std::lock_guard<std::mutex> lifecycle_lock(lifecycle_mutex_);
        return state_;
    }

    mutable std::mutex lifecycle_mutex_;
    std::shared_ptr<SharedState> state_;
    std::thread worker_;
};

WgcWindowCaptureSession::WgcWindowCaptureSession()
    : impl_(std::make_unique<Impl>()) { }

WgcWindowCaptureSession::~WgcWindowCaptureSession() = default;

WgcCaptureResult WgcWindowCaptureSession::Start(const WgcWindowCaptureConfig& config) {
    return impl_->Start(config);
}

void WgcWindowCaptureSession::Stop() noexcept { impl_->Stop(); }

bool WgcWindowCaptureSession::TryPopFrame(WgcNv12Frame* frame) {
    return impl_->TryPopFrame(frame);
}

bool WgcWindowCaptureSession::WaitPopFrame(WgcNv12Frame* frame,
                                           DWORD timeout_milliseconds) {
    return impl_->WaitPopFrame(frame, timeout_milliseconds);
}

bool WgcWindowCaptureSession::IsRunning() const noexcept { return impl_->IsRunning(); }

WgcWindowCaptureState WgcWindowCaptureSession::State() const noexcept {
    return impl_->State();
}

WgcCaptureStats WgcWindowCaptureSession::Stats() const noexcept { return impl_->Stats(); }

WgcCaptureResult WgcWindowCaptureSession::LastResult() const { return impl_->LastResult(); }

}  // namespace recorder::video
