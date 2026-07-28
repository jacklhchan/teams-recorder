#include "wasapi_capture.h"

#include <audioclient.h>
#include <propkey.h>
#include <functiondiscoverykeys_devpkey.h>
#include <mmdeviceapi.h>
#include <propvarutil.h>

#include <algorithm>
#include <atomic>
#include <memory>
#include <mutex>
#include <sstream>
#include <thread>
#include <utility>

namespace recorder::audio {
namespace {

template <typename T>
class ComPtr final {
public:
    ~ComPtr() { Reset(); }
    T* Get() const { return value_; }
    T** Put() { Reset(); return &value_; }
    T* operator->() const { return value_; }
    void Reset() { if (value_ != nullptr) { value_->Release(); value_ = nullptr; } }
private:
    T* value_ = nullptr;
};

class ScopedCoInitialize final {
public:
    ScopedCoInitialize() : result_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
    ~ScopedCoInitialize() { if (SUCCEEDED(result_)) { CoUninitialize(); } }
    HRESULT result() const { return result_; }
private:
    HRESULT result_;
};

class ScopedHandle final {
public:
    explicit ScopedHandle(HANDLE value = nullptr) : value_(value) {}
    ~ScopedHandle() { if (value_ != nullptr) { CloseHandle(value_); } }
    HANDLE Get() const { return value_; }
    HANDLE Release() { HANDLE result = value_; value_ = nullptr; return result; }
private:
    HANDLE value_;
};

bool IsDeviceInvalidated(HRESULT result) {
    return result == AUDCLNT_E_DEVICE_INVALIDATED;
}

std::wstring DescribeHresult(HRESULT result) {
    LPWSTR text = nullptr;
    const DWORD length = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                                            FORMAT_MESSAGE_IGNORE_INSERTS,
                                        nullptr, static_cast<DWORD>(result), 0,
                                        reinterpret_cast<LPWSTR>(&text), 0, nullptr);
    std::wstring message = length == 0 ? L"Unknown Windows error" : std::wstring(text, length);
    if (text != nullptr) { LocalFree(text); }
    return message;
}

HRESULT CreateEnumerator(ComPtr<IMMDeviceEnumerator>* enumerator) {
    return CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                            __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(enumerator->Put()));
}

HRESULT GetFriendlyName(IMMDevice* device, std::wstring* name) {
    ComPtr<IPropertyStore> properties;
    HRESULT result = device->OpenPropertyStore(STGM_READ, properties.Put());
    if (FAILED(result)) { return result; }
    PROPVARIANT value;
    PropVariantInit(&value);
    result = properties->GetValue(PKEY_Device_FriendlyName, &value);
    if (SUCCEEDED(result) && value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
        *name = value.pwszVal;
    } else if (SUCCEEDED(result)) {
        *name = L"(unnamed endpoint)";
    }
    PropVariantClear(&value);
    return result;
}

std::uint32_t DefaultFlagsFor(IMMDeviceEnumerator* enumerator, EDataFlow flow, const wchar_t* endpoint_id) {
    const ERole roles[] = { eConsole, eMultimedia, eCommunications };
    std::uint32_t flags = 0;
    for (std::uint32_t index = 0; index < 3; ++index) {
        ComPtr<IMMDevice> default_device;
        if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(flow, roles[index], default_device.Put()))) {
            LPWSTR default_id = nullptr;
            if (SUCCEEDED(default_device->GetId(&default_id))) {
                if (wcscmp(default_id, endpoint_id) == 0) { flags |= (1U << index); }
                CoTaskMemFree(default_id);
            }
        }
    }
    return flags;
}

HRESULT AppendEndpoints(IMMDeviceEnumerator* enumerator, EDataFlow flow,
                        EndpointFlow public_flow, std::vector<EndpointInfo>* endpoints) {
    ComPtr<IMMDeviceCollection> collection;
    HRESULT result = enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, collection.Put());
    if (FAILED(result)) { return result; }
    UINT count = 0;
    result = collection->GetCount(&count);
    if (FAILED(result)) { return result; }
    for (UINT index = 0; index < count; ++index) {
        ComPtr<IMMDevice> device;
        result = collection->Item(index, device.Put());
        if (FAILED(result)) { return result; }
        LPWSTR id = nullptr;
        result = device->GetId(&id);
        if (FAILED(result)) { return result; }
        EndpointInfo info;
        info.flow = public_flow;
        info.endpoint_id = id;
        CoTaskMemFree(id);
        result = GetFriendlyName(device.Get(), &info.friendly_name);
        if (FAILED(result)) { return result; }
        info.default_flags = DefaultFlagsFor(enumerator, flow, info.endpoint_id.c_str());
        endpoints->push_back(std::move(info));
    }
    return S_OK;
}

}  // namespace

WasapiCapture::WasapiCapture() = default;
WasapiCapture::~WasapiCapture() { Stop(); }

void WasapiCapture::SetError(HRESULT hresult, const wchar_t* context) {
    std::lock_guard<std::mutex> lock(mutex_);
    last_error_.hresult = hresult;
    last_error_.device_invalidated = IsDeviceInvalidated(hresult);
    last_error_.message = std::wstring(context) + L": " + DescribeHresult(hresult);
}

HRESULT WasapiCapture::EnumerateEndpoints(std::vector<EndpointInfo>* endpoints, CaptureError* error) {
    if (endpoints == nullptr || error == nullptr) { return E_POINTER; }
    endpoints->clear();
    *error = {};
    ScopedCoInitialize com;
    // An STA caller is already COM-initialized; it may still enumerate devices.
    if (FAILED(com.result()) && com.result() != RPC_E_CHANGED_MODE) {
        error->hresult = com.result(); error->message = L"CoInitializeEx failed: " + DescribeHresult(com.result());
        return com.result();
    }
    ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT result = CreateEnumerator(&enumerator);
    if (SUCCEEDED(result)) { result = AppendEndpoints(enumerator.Get(), eRender, EndpointFlow::Render, endpoints); }
    if (SUCCEEDED(result)) { result = AppendEndpoints(enumerator.Get(), eCapture, EndpointFlow::Capture, endpoints); }
    if (FAILED(result)) {
        endpoints->clear();
        error->hresult = result; error->device_invalidated = IsDeviceInvalidated(result);
        error->message = L"Endpoint enumeration failed: " + DescribeHresult(result);
    }
    return result;
}

bool WasapiCapture::Start(CaptureRequest request, AudioBlockCallback callback) {
    if (!callback) { SetError(E_INVALIDARG, L"Capture callback is empty"); return false; }
    ScopedHandle started(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (started.Get() == nullptr) { SetError(HRESULT_FROM_WIN32(GetLastError()), L"CreateEvent(started) failed"); return false; }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (worker_.joinable() || running_) { last_error_ = { E_UNEXPECTED, false, L"Capture is already active." }; return false; }
        stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (stop_event_ == nullptr) { last_error_ = { HRESULT_FROM_WIN32(GetLastError()), false, L"CreateEvent(stop) failed." }; return false; }
        last_error_ = {};
        worker_ = std::thread(&WasapiCapture::CaptureThread, this, std::move(request), std::move(callback), started.Get());
    }
    WaitForSingleObject(started.Get(), INFINITE);
    bool running = false;
    { std::lock_guard<std::mutex> lock(mutex_); running = running_; }
    if (!running) { Stop(); }  // Reap a failed initialization so a caller can retry.
    return running;
}

void WasapiCapture::Stop() {
    std::thread worker;
    HANDLE stop = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stop = stop_event_;
        if (stop != nullptr) { SetEvent(stop); }
        worker = std::move(worker_);
    }
    if (worker.joinable()) { worker.join(); }
    std::lock_guard<std::mutex> lock(mutex_);
    if (stop_event_ != nullptr) { CloseHandle(stop_event_); stop_event_ = nullptr; }
    running_ = false;
}

bool WasapiCapture::is_running() const { std::lock_guard<std::mutex> lock(mutex_); return running_; }
CaptureError WasapiCapture::last_error() const { std::lock_guard<std::mutex> lock(mutex_); return last_error_; }

void WasapiCapture::CaptureThread(CaptureRequest request, AudioBlockCallback callback, HANDLE started_event) {
    ScopedCoInitialize com;
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> device;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioCaptureClient> capture;
    WAVEFORMATEX* mix = nullptr;
    auto fail = [&](HRESULT result, const wchar_t* context) { SetError(result, context); SetEvent(started_event); };
    if (FAILED(com.result())) { fail(com.result(), L"CoInitializeEx failed"); return; }
    HRESULT result = CreateEnumerator(&enumerator);
    if (FAILED(result)) { fail(result, L"Creating device enumerator failed"); return; }
    const EDataFlow flow = request.flow == EndpointFlow::Render ? eRender : eCapture;
    if (request.endpoint_id.empty()) { result = enumerator->GetDefaultAudioEndpoint(flow, eConsole, device.Put()); }
    else { result = enumerator->GetDevice(request.endpoint_id.c_str(), device.Put()); }
    if (FAILED(result)) { fail(result, L"Selecting audio endpoint failed"); return; }
    result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.Put()));
    if (FAILED(result)) { fail(result, L"Activating IAudioClient failed"); return; }
    result = client->GetMixFormat(&mix);
    if (FAILED(result)) { fail(result, L"Getting endpoint mix format failed"); return; }
    DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                  (request.flow == EndpointFlow::Render ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0);
    // A non-zero requested duration is accepted across more desktop audio
    // drivers than the zero-duration low-latency form. The shared engine still
    // selects the actual buffer size and period.
    constexpr REFERENCE_TIME kRequestedBufferDuration100ns = 1'000'000;  // 100 ms
    result = client->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        flags,
        kRequestedBufferDuration100ns,
        0,
        mix,
        nullptr);
    bool event_driven = true;
    if (FAILED(result) && request.flow == EndpointFlow::Capture) {
        // Some virtual microphone drivers reject EVENTCALLBACK even for their
        // own shared-mode mix format. Re-activate a fresh client and use
        // bounded polling; never fall back to a different endpoint or flow.
        CoTaskMemFree(mix);
        mix = nullptr;
        client.Reset();
        result = device->Activate(
            __uuidof(IAudioClient),
            CLSCTX_ALL,
            nullptr,
            reinterpret_cast<void**>(client.Put()));
        if (SUCCEEDED(result)) {
            result = client->GetMixFormat(&mix);
        }
        flags = 0;
        if (SUCCEEDED(result)) {
            result = client->Initialize(
                AUDCLNT_SHAREMODE_SHARED,
                flags,
                0,
                0,
                mix,
                nullptr);
        }
        event_driven = false;
    }
    if (FAILED(result)) {
        std::wostringstream context;
        context << L"Initializing shared WASAPI capture failed"
                << L" (tag=" << mix->wFormatTag
                << L", channels=" << mix->nChannels
                << L", sampleRate=" << mix->nSamplesPerSec
                << L", avgBytes=" << mix->nAvgBytesPerSec
                << L", blockAlign=" << mix->nBlockAlign
                << L", bits=" << mix->wBitsPerSample
                << L", cbSize=" << mix->cbSize
                << L")";
        const std::wstring message = context.str();
        CoTaskMemFree(mix);
        fail(result, message.c_str());
        return;
    }
    const WORD block_align = mix->nBlockAlign;
    std::vector<std::uint8_t> format_bytes(reinterpret_cast<std::uint8_t*>(mix),
                                           reinterpret_cast<std::uint8_t*>(mix) + sizeof(WAVEFORMATEX) + mix->cbSize);
    CoTaskMemFree(mix); mix = nullptr;
    ScopedHandle audio_event(event_driven ? CreateEventW(nullptr, FALSE, FALSE, nullptr) : nullptr);
    if (event_driven) {
        if (audio_event.Get() == nullptr) { fail(HRESULT_FROM_WIN32(GetLastError()), L"CreateEvent(audio) failed"); return; }
        result = client->SetEventHandle(audio_event.Get());
        if (FAILED(result)) { fail(result, L"Setting WASAPI event handle failed"); return; }
    }
    result = client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void**>(capture.Put()));
    if (FAILED(result)) { fail(result, L"Getting IAudioCaptureClient failed"); return; }
    result = client->Start();
    if (FAILED(result)) { fail(result, L"Starting WASAPI capture failed"); return; }
    { std::lock_guard<std::mutex> lock(mutex_); running_ = true; }
    SetEvent(started_event);

    HANDLE waits[] = { stop_event_, audio_event.Get() };
    bool keep_capturing = true;
    while (keep_capturing) {
        const DWORD waited = event_driven
            ? WaitForMultipleObjects(2, waits, FALSE, INFINITE)
            : WaitForSingleObject(stop_event_, 10);
        if (waited == WAIT_OBJECT_0) { break; }
        if ((event_driven && waited != WAIT_OBJECT_0 + 1) ||
            (!event_driven && waited != WAIT_TIMEOUT)) {
            SetError(HRESULT_FROM_WIN32(GetLastError()), L"Waiting for WASAPI capture failed");
            break;
        }
        UINT32 packets = 0;
        while (SUCCEEDED(result = capture->GetNextPacketSize(&packets)) && packets != 0) {
            BYTE* data = nullptr; UINT32 frames = 0; DWORD packet_flags = 0; UINT64 position = 0; UINT64 qpc = 0;
            result = capture->GetBuffer(&data, &frames, &packet_flags, &position, &qpc);
            if (FAILED(result)) { break; }
            AudioBlock block;
            block.mix_format_bytes = format_bytes;
            block.frame_count = frames;
            block.device_position_frames = position;
            block.qpc_position = qpc;
            block.silent = (packet_flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
            block.discontinuity = (packet_flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0;
            block.event_driven = event_driven;
            // A silent WASAPI packet can have a null data pointer. Preserve that fact rather than invent zeros.
            if (!block.silent && data != nullptr) { block.bytes.assign(data, data + frames * block_align); }
            const HRESULT release = capture->ReleaseBuffer(frames);
            if (FAILED(release)) { result = release; break; }
            try { callback(std::move(block)); }
            catch (...) { result = E_FAIL; break; }
            packets = 0;
        }
        if (FAILED(result)) { SetError(result, L"Reading WASAPI capture packet failed"); keep_capturing = false; }
    }
    const HRESULT stop_result = client->Stop();
    if (FAILED(stop_result) &&
        (SUCCEEDED(result) || stop_result == AUDCLNT_E_DEVICE_INVALIDATED)) {
        SetError(stop_result, L"Stopping WASAPI capture failed");
    }
    { std::lock_guard<std::mutex> lock(mutex_); running_ = false; }
}

}  // namespace recorder::audio
