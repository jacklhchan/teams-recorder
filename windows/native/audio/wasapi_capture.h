#pragma once

// Windows-only WASAPI capture boundary. This API deliberately exposes raw shared-mode data.

#include <windows.h>

#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace recorder::audio {

enum class EndpointFlow { Render, Capture };

enum DefaultEndpointFlags : std::uint32_t {
    DefaultForConsole = 1U << 0,
    DefaultForMultimedia = 1U << 1,
    DefaultForCommunications = 1U << 2,
};

struct EndpointInfo {
    EndpointFlow flow;
    std::wstring endpoint_id;
    std::wstring friendly_name;
    std::uint32_t default_flags = 0;
};

struct CaptureError {
    HRESULT hresult = S_OK;
    bool device_invalidated = false;
    std::wstring message;
};

struct AudioBlock {
    // The callback owns this object and its vectors after invocation.
    std::vector<std::uint8_t> bytes;
    // Exact WAVEFORMATEX blob returned by IAudioClient::GetMixFormat().
    std::vector<std::uint8_t> mix_format_bytes;
    std::uint32_t frame_count = 0;
    std::uint64_t device_position_frames = 0;
    std::uint64_t qpc_position = 0;
    bool silent = false;
    bool discontinuity = false;
    // False means the endpoint rejected event-callback initialization and the
    // capture worker used bounded polling for this packet.
    bool event_driven = true;
};

// Invoked on the capture thread; Stop must be called from a different thread.
using AudioBlockCallback = std::function<void(AudioBlock&&)>;

struct CaptureRequest {
    // Capture means a physical/input endpoint. Render means loopback of a render endpoint.
    EndpointFlow flow = EndpointFlow::Capture;
    // Empty selects the current default endpoint for the selected flow.
    std::wstring endpoint_id;
};

class WasapiCapture final {
public:
    WasapiCapture();
    ~WasapiCapture();
    WasapiCapture(const WasapiCapture&) = delete;
    WasapiCapture& operator=(const WasapiCapture&) = delete;

    // Starts event-driven shared-mode capture. Returns false and fills last_error on failure.
    bool Start(CaptureRequest request, AudioBlockCallback callback);
    void Stop();
    bool is_running() const;
    CaptureError last_error() const;

    // Enumerates active render and capture endpoints. The caller does not need COM initialized.
    static HRESULT EnumerateEndpoints(std::vector<EndpointInfo>* endpoints, CaptureError* error);

private:
    void CaptureThread(CaptureRequest request, AudioBlockCallback callback, HANDLE started_event);
    void CaptureWithMediaFoundationFallback(
        const CaptureRequest& request,
        const AudioBlockCallback& callback,
        HANDLE started_event,
        const std::wstring& wasapi_error);
    void SetError(HRESULT hresult, const wchar_t* context);

    mutable std::mutex mutex_;
    std::thread worker_;
    HANDLE stop_event_ = nullptr;
    bool running_ = false;
    CaptureError last_error_;
};

}  // namespace recorder::audio
