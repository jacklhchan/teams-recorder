#include "wasapi_capture.h"

#include <audioclient.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propkey.h>
#include <functiondiscoverykeys_devpkey.h>
#include <mmdeviceapi.h>
#include <propvarutil.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <memory>
#include <mutex>
#include <limits>
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
    HRESULT As(REFIID iid, void** result) const {
        if (result == nullptr) { return E_POINTER; }
        *result = nullptr;
        return value_ == nullptr ? E_NOINTERFACE : value_->QueryInterface(iid, result);
    }
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

class ScopedMfStartup final {
public:
    ScopedMfStartup() : result_(MFStartup(MF_VERSION, MFSTARTUP_LITE)) {}
    ~ScopedMfStartup() { if (SUCCEEDED(result_)) { MFShutdown(); } }
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

std::uint64_t CurrentQpc100ns() {
    LARGE_INTEGER frequency{};
    LARGE_INTEGER counter{};
    if (QueryPerformanceFrequency(&frequency) == 0 ||
        QueryPerformanceCounter(&counter) == 0 || frequency.QuadPart <= 0) {
        return 0;
    }
    const auto ticks = static_cast<std::uint64_t>(counter.QuadPart);
    const auto rate = static_cast<std::uint64_t>(frequency.QuadPart);
    return ticks > (std::numeric_limits<std::uint64_t>::max)() / 10'000'000U
        ? ticks / rate * 10'000'000U
        : ticks * 10'000'000U / rate;
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

std::wstring DescribeGuid(REFGUID value) {
    wchar_t text[40]{};
    return StringFromGUID2(value, text, static_cast<int>(std::size(text))) == 0
        ? L"(unavailable)" : std::wstring(text);
}

std::wstring DescribeFormat(const WAVEFORMATEX* format) {
    if (format == nullptr) { return L"unavailable"; }
    std::wostringstream description;
    description << L"tag=" << format->wFormatTag
                << L", channels=" << format->nChannels
                << L", sampleRate=" << format->nSamplesPerSec
                << L", avgBytes=" << format->nAvgBytesPerSec
                << L", blockAlign=" << format->nBlockAlign
                << L", bits=" << format->wBitsPerSample
                << L", cbSize=" << format->cbSize;
    constexpr WORD extensible_extra_bytes =
        static_cast<WORD>(sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX));
    if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE && format->cbSize >= extensible_extra_bytes) {
        const auto* extensible = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
        description << L", validBits=" << extensible->Samples.wValidBitsPerSample
                    << L", channelMask=0x" << std::hex << extensible->dwChannelMask
                    << L", subFormat=" << DescribeGuid(extensible->SubFormat);
    }
    return description.str();
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
    last_error_.stage = context == nullptr ? L"(unspecified)" : context;
    last_error_.message = std::wstring(context) + L": " + DescribeHresult(hresult);
}

void WasapiCapture::SetEndpointDiagnostics(
    const std::wstring& endpoint_id,
    const std::wstring& endpoint_name,
    const wchar_t* stage) {
    std::lock_guard<std::mutex> lock(mutex_);
    last_error_.endpoint_id = endpoint_id;
    last_error_.endpoint_name = endpoint_name;
    last_error_.stage = stage == nullptr ? L"(unspecified)" : stage;
}

void WasapiCapture::SetStage(const wchar_t* stage) {
    std::lock_guard<std::mutex> lock(mutex_);
    last_error_.stage = stage == nullptr ? L"(unspecified)" : stage;
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
        if (worker_.joinable() || running_) {
            last_error_.hresult = E_UNEXPECTED;
            last_error_.device_invalidated = false;
            last_error_.stage = L"starting capture";
            last_error_.message = L"Capture is already active.";
            return false;
        }
        stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (stop_event_ == nullptr) {
            last_error_.hresult = HRESULT_FROM_WIN32(GetLastError());
            last_error_.device_invalidated = false;
            last_error_.stage = L"creating stop event";
            last_error_.message = L"CreateEvent(stop) failed.";
            return false;
        }
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

void WasapiCapture::CaptureWithMediaFoundationFallback(
    const CaptureRequest& request,
    const AudioBlockCallback& callback,
    HANDLE started_event,
    const std::wstring& wasapi_error) {
    ScopedMfStartup media_foundation;
    ComPtr<IMFAttributes> device_attributes;
    ComPtr<IMFMediaSource> media_source;
    ComPtr<IMFSourceReader> reader;
    WAVEFORMATEX* wave_format = nullptr;
    std::vector<std::uint8_t> format_bytes;
    std::uint64_t device_position_frames = 0;
    const wchar_t* phase = L"starting Media Foundation";

    auto fail = [&](HRESULT result, const wchar_t* context) {
        std::wstring diagnostic = L"Media Foundation microphone fallback failed after WASAPI rejected the selected endpoint";
        if (!wasapi_error.empty()) {
            diagnostic += L" (" + wasapi_error + L")";
        }
        diagnostic += L" at ";
        diagnostic += phase;
        diagnostic += L": ";
        diagnostic += context;
        SetError(result, diagnostic.c_str());
        SetEvent(started_event);
    };
    auto cleanup = [&] {
        if (wave_format != nullptr) {
            CoTaskMemFree(wave_format);
            wave_format = nullptr;
        }
        reader.Reset();
        if (media_source.Get() != nullptr) {
            (void)media_source->Shutdown();
        }
        std::lock_guard<std::mutex> lock(mutex_);
        running_ = false;
    };

    HRESULT result = media_foundation.result();
    if (FAILED(result)) {
        fail(result, L"MFStartup failed");
        cleanup();
        return;
    }
    phase = L"creating device attributes";
    result = MFCreateAttributes(device_attributes.Put(), 2);
    if (SUCCEEDED(result)) {
        phase = L"setting capture source type";
        result = device_attributes->SetGUID(
            MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
            MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_GUID);
    }
    if (SUCCEEDED(result) && !request.endpoint_id.empty()) {
        phase = L"setting capture endpoint id";
        result = device_attributes->SetString(
            MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_ENDPOINT_ID,
            request.endpoint_id.c_str());
    }
    if (SUCCEEDED(result)) {
        phase = L"creating capture device source";
        result = MFCreateDeviceSource(device_attributes.Get(), media_source.Put());
    }
    if (SUCCEEDED(result)) {
        phase = L"creating capture source reader";
        result = MFCreateSourceReaderFromMediaSource(media_source.Get(), nullptr, reader.Put());
    }
    if (SUCCEEDED(result)) {
        phase = L"disabling unrelated source streams";
        result = reader->SetStreamSelection(
            static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
    }
    if (SUCCEEDED(result)) {
        phase = L"selecting the audio stream";
        result = reader->SetStreamSelection(
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), TRUE);
    }
    ComPtr<IMFMediaType> media_type;
    if (SUCCEEDED(result)) {
        phase = L"reading the audio stream format";
        result = reader->GetCurrentMediaType(
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), media_type.Put());
    }
    UINT32 wave_format_bytes = 0;
    if (SUCCEEDED(result)) {
        phase = L"converting the audio stream format";
        result = MFCreateWaveFormatExFromMFMediaType(
            media_type.Get(),
            &wave_format,
            &wave_format_bytes,
            MFWaveFormatExConvertFlag_Normal);
    }
    if (FAILED(result) || wave_format == nullptr || wave_format->nBlockAlign == 0 ||
        wave_format->nSamplesPerSec == 0 || wave_format_bytes < sizeof(WAVEFORMATEX)) {
        fail(FAILED(result) ? result : E_INVALIDARG,
             L"Opening the selected capture endpoint failed");
        cleanup();
        return;
    }
    format_bytes.assign(
        reinterpret_cast<const std::uint8_t*>(wave_format),
        reinterpret_cast<const std::uint8_t*>(wave_format) + wave_format_bytes);
    const WORD block_align = wave_format->nBlockAlign;
    CoTaskMemFree(wave_format);
    wave_format = nullptr;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        running_ = true;
    }
    SetEvent(started_event);

    while (WaitForSingleObject(stop_event_, 0) != WAIT_OBJECT_0) {
        DWORD stream_index = 0;
        DWORD stream_flags = 0;
        LONGLONG sample_time = 0;
        ComPtr<IMFSample> sample;
        result = reader->ReadSample(
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
            0,
            &stream_index,
            &stream_flags,
            &sample_time,
            sample.Put());
        if (FAILED(result)) {
            if (WaitForSingleObject(stop_event_, 0) != WAIT_OBJECT_0) {
                SetError(result, L"Reading Media Foundation microphone sample failed");
            }
            break;
        }
        if ((stream_flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
            if (WaitForSingleObject(stop_event_, 0) != WAIT_OBJECT_0) {
                SetError(E_FAIL, L"Media Foundation microphone stream ended unexpectedly");
            }
            break;
        }
        if ((stream_flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0) {
            SetError(E_FAIL, L"Media Foundation microphone format changed during capture");
            break;
        }
        if (sample.Get() == nullptr) {
            continue;
        }
        ComPtr<IMFMediaBuffer> buffer;
        result = sample->ConvertToContiguousBuffer(buffer.Put());
        if (FAILED(result)) {
            SetError(result, L"Combining Media Foundation microphone buffers failed");
            break;
        }
        BYTE* bytes = nullptr;
        DWORD capacity = 0;
        DWORD byte_count = 0;
        result = buffer->Lock(&bytes, &capacity, &byte_count);
        if (FAILED(result)) {
            SetError(result, L"Locking Media Foundation microphone buffer failed");
            break;
        }
        if (byte_count % block_align != 0) {
            (void)buffer->Unlock();
            SetError(E_INVALIDARG, L"Media Foundation microphone packet has invalid block alignment");
            break;
        }
        AudioBlock block;
        block.mix_format_bytes = format_bytes;
        block.frame_count = byte_count / block_align;
        block.device_position_frames = device_position_frames;
        block.qpc_position = CurrentQpc100ns();
        block.silent = byte_count == 0;
        block.discontinuity = (stream_flags & MF_SOURCE_READERF_STREAMTICK) != 0;
        block.event_driven = false;
        if (!block.silent && bytes != nullptr) {
            block.bytes.assign(bytes, bytes + byte_count);
        }
        const HRESULT unlock_result = buffer->Unlock();
        if (FAILED(unlock_result)) {
            SetError(unlock_result, L"Unlocking Media Foundation microphone buffer failed");
            break;
        }
        try {
            callback(std::move(block));
        }
        catch (...) {
            SetError(E_FAIL, L"Media Foundation microphone callback failed");
            break;
        }
        device_position_frames += byte_count / block_align;
    }
    cleanup();
}

void WasapiCapture::CaptureThread(CaptureRequest request, AudioBlockCallback callback, HANDLE started_event) {
    ScopedCoInitialize com;
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> device;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioCaptureClient> capture;
    WAVEFORMATEX* mix = nullptr;
    struct FormatDescription {
        bool available = false;
        WORD tag = 0;
        WORD channels = 0;
        DWORD sample_rate = 0;
        DWORD average_bytes = 0;
        WORD block_align = 0;
        WORD bits = 0;
        WORD extra_bytes = 0;
    } endpoint_format;
    auto remember_endpoint_format = [&]() {
        if (mix == nullptr || endpoint_format.available) { return; }
        endpoint_format = {
            true,
            mix->wFormatTag,
            mix->nChannels,
            mix->nSamplesPerSec,
            mix->nAvgBytesPerSec,
            mix->nBlockAlign,
            mix->wBitsPerSample,
            mix->cbSize,
        };
    };
    auto fail = [&](HRESULT result, const wchar_t* context) { SetError(result, context); SetEvent(started_event); };
    if (FAILED(com.result())) { fail(com.result(), L"CoInitializeEx failed"); return; }
    HRESULT result = CreateEnumerator(&enumerator);
    if (FAILED(result)) { fail(result, L"Creating device enumerator failed"); return; }
    const EDataFlow flow = request.flow == EndpointFlow::Render ? eRender : eCapture;
    if (request.endpoint_id.empty()) { result = enumerator->GetDefaultAudioEndpoint(flow, eConsole, device.Put()); }
    else { result = enumerator->GetDevice(request.endpoint_id.c_str(), device.Put()); }
    if (FAILED(result)) { fail(result, L"Selecting audio endpoint failed"); return; }
    std::wstring selected_endpoint_id;
    std::wstring selected_friendly_name;
    LPWSTR selected_id = nullptr;
    if (SUCCEEDED(device->GetId(&selected_id)) && selected_id != nullptr) {
        selected_endpoint_id = selected_id;
        CoTaskMemFree(selected_id);
    }
    (void)GetFriendlyName(device.Get(), &selected_friendly_name);
    SetEndpointDiagnostics(
        selected_endpoint_id,
        selected_friendly_name,
        request.flow == EndpointFlow::Render
            ? L"selected render loopback endpoint"
            : L"selected microphone endpoint");
    result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.Put()));
    if (FAILED(result)) {
        if (request.flow == EndpointFlow::Capture && IsDeviceInvalidated(result)) {
            // An active-enumeration entry can become stale when a Bluetooth
            // headset switches profile or disconnects.  It is not safe to
            // substitute another endpoint, especially not system loopback.
            fail(
                result,
                L"The selected microphone was invalidated by Windows. Reconnect the headset, then refresh and select its current Headset microphone");
        } else if (request.flow == EndpointFlow::Capture) {
            CaptureWithMediaFoundationFallback(
                request, callback, started_event, L"Activating IAudioClient failed");
        } else {
            fail(result, L"Activating IAudioClient failed");
        }
        return;
    }
    result = client->GetMixFormat(&mix);
    if (FAILED(result)) {
        if (request.flow == EndpointFlow::Capture) {
            CaptureWithMediaFoundationFallback(
                request, callback, started_event, L"Getting endpoint mix format failed");
        } else {
            fail(result, L"Getting endpoint mix format failed");
        }
        return;
    }
    remember_endpoint_format();
    const DWORD base_flags = request.flow == EndpointFlow::Render
        ? AUDCLNT_STREAMFLAGS_LOOPBACK
        : 0;
    // Capture drivers vary more than render drivers in their accepted shared
    // buffer duration. Re-activate a fresh IAudioClient for every attempt as
    // required after a failed Initialize call; never substitute the endpoint.
    struct InitializeAttempt {
        DWORD additional_flags;
        REFERENCE_TIME buffer_duration_100ns;
        bool event_driven;
    };
    REFERENCE_TIME driver_default_period_100ns = 0;
    const HRESULT driver_period_result = client->GetDevicePeriod(
        &driver_default_period_100ns,
        nullptr);
    const std::array<InitializeAttempt, 5> attempts = {{
        { AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 1'000'000, true },
        { AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 0, true },
        { 0, 0, false },
        { AUDCLNT_STREAMFLAGS_NOPERSIST, 1'000'000, false },
        // Some older capture drivers reject both zero and an arbitrary
        // duration, but accept the endpoint's own shared-device period.
        { AUDCLNT_STREAMFLAGS_EVENTCALLBACK, driver_default_period_100ns, true },
    }};

    auto initialize_attempt = [&](const InitializeAttempt& attempt, HRESULT* support_result) {
        if (support_result != nullptr) { *support_result = E_UNEXPECTED; }
        if (mix != nullptr) {
            CoTaskMemFree(mix);
            mix = nullptr;
        }
        client.Reset();
        HRESULT attempt_result = device->Activate(
            __uuidof(IAudioClient),
            CLSCTX_ALL,
            nullptr,
            reinterpret_cast<void**>(client.Put()));
        if (SUCCEEDED(attempt_result)) {
            attempt_result = client->GetMixFormat(&mix);
            remember_endpoint_format();
        }
        if (SUCCEEDED(attempt_result)) {
            WAVEFORMATEX* closest = nullptr;
            const HRESULT support = client->IsFormatSupported(
                AUDCLNT_SHAREMODE_SHARED, mix, &closest);
            if (support_result != nullptr) { *support_result = support; }
            if (support == S_FALSE && closest != nullptr) {
                CoTaskMemFree(mix);
                mix = closest;
            } else if (closest != nullptr) {
                CoTaskMemFree(closest);
            }
        }
        if (SUCCEEDED(attempt_result)) {
            attempt_result = client->Initialize(
                AUDCLNT_SHAREMODE_SHARED,
                base_flags | attempt.additional_flags,
                attempt.buffer_duration_100ns,
                0,
                mix,
                nullptr);
        }
        return attempt_result;
    };

    bool event_driven = true;
    result = E_FAIL;
    std::array<HRESULT, attempts.size()> attempt_results{};
    std::array<HRESULT, attempts.size()> attempt_support_results{};
    std::size_t attempt_count = 0;
    HRESULT client3_result = E_NOTIMPL;
    HRESULT communications_category_result = E_NOTIMPL;
    std::wstring original_mix_description;
    for (const InitializeAttempt& attempt : attempts) {
        HRESULT support_result = E_UNEXPECTED;
        result = initialize_attempt(attempt, &support_result);
        attempt_results[attempt_count++] = result;
        attempt_support_results[attempt_count - 1] = support_result;
        if (SUCCEEDED(result)) {
            event_driven = attempt.event_driven;
            break;
        }
    }
    // Intel/USB microphone stacks can apply capture signal processing only
    // for a communications stream. This is still the explicitly selected
    // endpoint and exact mix format; it is a compatibility retry, never a
    // fallback to another microphone or to system loopback.
    if (FAILED(result) && request.flow == EndpointFlow::Capture) {
        if (mix != nullptr) { CoTaskMemFree(mix); mix = nullptr; }
        client.Reset();
        result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                  reinterpret_cast<void**>(client.Put()));
        if (SUCCEEDED(result)) result = client->GetMixFormat(&mix);
        if (SUCCEEDED(result)) {
            ComPtr<IAudioClient2> client2;
            communications_category_result = client.As(
                __uuidof(IAudioClient2), reinterpret_cast<void**>(client2.Put()));
            if (SUCCEEDED(communications_category_result)) {
                AudioClientProperties properties{};
                properties.cbSize = sizeof(properties);
                properties.bIsOffload = FALSE;
                properties.eCategory = AudioCategory_Communications;
                properties.Options = AUDCLNT_STREAMOPTIONS_NONE;
                communications_category_result = client2->SetClientProperties(&properties);
            }
            if (SUCCEEDED(communications_category_result)) {
                result = client->Initialize(
                    AUDCLNT_SHAREMODE_SHARED,
                    base_flags | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                    driver_default_period_100ns,
                    0,
                    mix,
                    nullptr);
                if (SUCCEEDED(result)) {
                    event_driven = true;
                }
            } else {
                result = communications_category_result;
            }
        }
    }
    // Some USB/array microphones advertise an extensible multichannel float
    // mix format but reject every IAudioClient::Initialize shared-mode variant.
    // IAudioClient3 obtains the driver-selected shared engine period instead of
    // guessing a duration; it preserves the exact selected endpoint and mix
    // format (there is no fallback to another microphone or to stereo).
    const bool try_client3 =
        FAILED(result) && request.flow == EndpointFlow::Capture;
    if (try_client3) {
        if (mix != nullptr) {
            original_mix_description = DescribeFormat(mix);
        }
        if (mix != nullptr) { CoTaskMemFree(mix); mix = nullptr; }
        client.Reset();
        result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                  reinterpret_cast<void**>(client.Put()));
        if (SUCCEEDED(result)) result = client->GetMixFormat(&mix);
        if (SUCCEEDED(result)) {
            WAVEFORMATEX* closest = nullptr;
            const HRESULT support = client->IsFormatSupported(
                AUDCLNT_SHAREMODE_SHARED, mix, &closest);
            if (support == S_FALSE && closest != nullptr) {
                CoTaskMemFree(mix);
                mix = closest;
            } else if (closest != nullptr) {
                CoTaskMemFree(closest);
            }
        }
    }
    if (try_client3 && client.Get() != nullptr && mix != nullptr) {
        ComPtr<IAudioClient3> client3;
        const HRESULT query_result = client.As(__uuidof(IAudioClient3),
                                               reinterpret_cast<void**>(client3.Put()));
        if (SUCCEEDED(query_result)) {
            UINT32 default_period_frames = 0;
            UINT32 fundamental_period_frames = 0;
            UINT32 minimum_period_frames = 0;
            UINT32 maximum_period_frames = 0;
            client3_result = client3->GetSharedModeEnginePeriod(
                mix,
                &default_period_frames,
                &fundamental_period_frames,
                &minimum_period_frames,
                &maximum_period_frames);
            if (SUCCEEDED(client3_result)) {
                client3_result = client3->InitializeSharedAudioStream(
                    base_flags | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                    default_period_frames,
                    mix,
                    nullptr);
            }
            if (SUCCEEDED(client3_result)) {
                result = S_OK;
                event_driven = true;
            } else {
                result = client3_result;
            }
        } else {
            client3_result = query_result;
            result = query_result;
        }
    }
    // Last-resort shared-engine conversion for drivers that publish an
    // unusable multichannel float mix format.  This remains on the selected
    // endpoint; Windows only converts its stream format to the canonical
    // 48 kHz stereo float form already consumed by the recorder pipeline.
    if (FAILED(result) && request.flow == EndpointFlow::Capture) {
        if (mix != nullptr) { CoTaskMemFree(mix); mix = nullptr; }
        client.Reset();
        result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                  reinterpret_cast<void**>(client.Put()));
        WAVEFORMATEX canonical{};
        canonical.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
        canonical.nChannels = 2;
        canonical.nSamplesPerSec = 48'000;
        canonical.wBitsPerSample = 32;
        canonical.nBlockAlign = 8;
        canonical.nAvgBytesPerSec = 384'000;
        HRESULT canonical_support_result = E_UNEXPECTED;
        if (SUCCEEDED(result)) {
            WAVEFORMATEX* closest = nullptr;
            canonical_support_result = client->IsFormatSupported(
                AUDCLNT_SHAREMODE_SHARED, &canonical, &closest);
            if (closest != nullptr) { CoTaskMemFree(closest); }
            result = client->Initialize(
                AUDCLNT_SHAREMODE_SHARED,
                AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                    AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                0,
                0,
                &canonical,
                nullptr);
        }
        if (SUCCEEDED(result)) {
            mix = static_cast<WAVEFORMATEX*>(CoTaskMemAlloc(sizeof(canonical)));
            if (mix == nullptr) {
                result = E_OUTOFMEMORY;
            } else {
                *mix = canonical;
                event_driven = false;
            }
        }
        if (FAILED(result)) {
            std::wostringstream support_text;
            support_text << L"; canonical48kStereoFloatSupport=0x" << std::hex
                         << static_cast<unsigned long>(canonical_support_result);
            original_mix_description += support_text.str();
        }
    }
    if (FAILED(result)) {
        std::wostringstream context;
        context << L"Initializing shared WASAPI capture failed";
        if (!selected_friendly_name.empty()) {
            context << L" (endpoint='" << selected_friendly_name << L"'";
            if (!selected_endpoint_id.empty()) { context << L", id='" << selected_endpoint_id << L"'"; }
            context << L")";
        }
        if (!original_mix_description.empty()) {
            context << L" (original endpoint mix " << original_mix_description << L")";
        } else if (mix != nullptr) {
            context << L" (" << DescribeFormat(mix) << L")";
        } else if (endpoint_format.available) {
            context << L" (endpoint tag=" << endpoint_format.tag
                    << L", channels=" << endpoint_format.channels
                    << L", sampleRate=" << endpoint_format.sample_rate
                    << L", avgBytes=" << endpoint_format.average_bytes
                    << L", blockAlign=" << endpoint_format.block_align
                    << L", bits=" << endpoint_format.bits
                    << L", cbSize=" << endpoint_format.extra_bytes
                    << L")";
        } else {
            context << L" (endpoint mix format unavailable)";
        }
        if (try_client3) {
            context << L"; client3=0x" << std::hex
                    << static_cast<unsigned long>(client3_result);
        }
        context << L"; devicePeriod=0x" << std::hex
                << static_cast<unsigned long>(driver_period_result)
                << L"/" << std::dec << driver_default_period_100ns
                << L"; communicationsCategory=0x" << std::hex
                << static_cast<unsigned long>(communications_category_result);
        context << L"; attempts=";
        for (std::size_t index = 0; index < attempt_count; ++index) {
            if (index != 0) { context << L","; }
            context << L"0x" << std::hex << static_cast<unsigned long>(attempt_results[index])
                    << L"/formatSupport=0x"
                    << static_cast<unsigned long>(attempt_support_results[index]);
        }
        const std::wstring message = context.str();
        if (mix != nullptr) {
            CoTaskMemFree(mix);
        }
        if (request.flow == EndpointFlow::Capture) {
            CaptureWithMediaFoundationFallback(request, callback, started_event, message);
            return;
        }
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
    SetStage(event_driven ? L"reading event-driven WASAPI packets"
                          : L"reading polling WASAPI packets");
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
    {
        std::lock_guard<std::mutex> lock(mutex_);
        running_ = false;
        if (last_error_.hresult == S_OK && WaitForSingleObject(stop_event_, 0) != WAIT_OBJECT_0) {
            last_error_.stage = L"WASAPI capture worker stopped without an HRESULT";
        }
    }
}

}  // namespace recorder::audio
