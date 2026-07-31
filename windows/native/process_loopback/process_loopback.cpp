#include "process_loopback.h"

#include <mmdeviceapi.h>
#include <propvarutil.h>
#include <winternl.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <new>
#include <sstream>
#include <utility>

namespace teams_recorder::process_loopback {
namespace {

class ScopedHandle {
public:
    explicit ScopedHandle(HANDLE value = nullptr) noexcept : value_(value) {}
    ~ScopedHandle() { reset(); }
    ScopedHandle(const ScopedHandle&) = delete;
    ScopedHandle& operator=(const ScopedHandle&) = delete;
    ScopedHandle(ScopedHandle&& other) noexcept : value_(other.release()) {}
    ScopedHandle& operator=(ScopedHandle&& other) noexcept {
        if (this != &other) {
            reset(other.release());
        }
        return *this;
    }

    HANDLE get() const noexcept { return value_; }
    HANDLE release() noexcept {
        HANDLE value = value_;
        value_ = nullptr;
        return value;
    }
    void reset(HANDLE replacement = nullptr) noexcept {
        if (value_ != nullptr && value_ != INVALID_HANDLE_VALUE) {
            CloseHandle(value_);
        }
        value_ = replacement;
    }

private:
    HANDLE value_;
};

class ScopedCoInitialize {
public:
    ScopedCoInitialize() noexcept : result_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
    ~ScopedCoInitialize() {
        if (SUCCEEDED(result_)) {
            CoUninitialize();
        }
    }
    HRESULT result() const noexcept { return result_; }

private:
    HRESULT result_;
};

template <typename T>
class ComPtr {
public:
    ComPtr() noexcept = default;
    ~ComPtr() { reset(); }
    ComPtr(const ComPtr&) = delete;
    ComPtr& operator=(const ComPtr&) = delete;
    T* get() const noexcept { return value_; }
    T** put() noexcept { reset(); return &value_; }
    T* operator->() const noexcept { return value_; }
    void reset(T* replacement = nullptr) noexcept {
        if (value_ != nullptr) {
            value_->Release();
        }
        value_ = replacement;
    }

private:
    T* value_ = nullptr;
};

bool IsDeviceInvalidated(HRESULT result) noexcept {
    return result == AUDCLNT_E_DEVICE_INVALIDATED;
}

std::wstring DescribeHresult(HRESULT result) {
    LPWSTR text = nullptr;
    const DWORD length = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr,
        static_cast<DWORD>(result),
        0,
        reinterpret_cast<LPWSTR>(&text),
        0,
        nullptr);
    std::wstring message = length == 0 ? L"Unknown Windows error" : std::wstring(text, length);
    if (text != nullptr) {
        LocalFree(text);
    }
    return message;
}

struct ActivationState {
    explicit ActivationState() : completed(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}

    ScopedHandle completed;
    std::mutex mutex;
    bool abandoned = false;
    bool callback_received = false;
    HRESULT activation_hr = E_FAIL;
    IAudioClient* audio_client = nullptr;
    // The blob is kept alive until the asynchronous completion callback runs.
    AUDIOCLIENT_ACTIVATION_PARAMS activation_params{};
    PROPVARIANT activation_propvariant{};

    ~ActivationState() {
        if (audio_client != nullptr) {
            audio_client->Release();
        }
    }
};

class ActivationCompletionHandler final : public IActivateAudioInterfaceCompletionHandler,
                                        public IAgileObject {
public:
    explicit ActivationCompletionHandler(std::shared_ptr<ActivationState> state) noexcept
        : state_(std::move(state)) {}

    STDMETHODIMP QueryInterface(REFIID riid, void** object) override {
        if (object == nullptr) {
            return E_POINTER;
        }
        *object = nullptr;
        if (riid == __uuidof(IUnknown) ||
            riid == __uuidof(IActivateAudioInterfaceCompletionHandler)) {
            *object = static_cast<IActivateAudioInterfaceCompletionHandler*>(this);
            AddRef();
            return S_OK;
        }
        if (riid == __uuidof(IAgileObject)) {
            *object = static_cast<IAgileObject*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    STDMETHODIMP_(ULONG) AddRef() override { return ++reference_count_; }

    STDMETHODIMP_(ULONG) Release() override {
        const ULONG remaining = --reference_count_;
        if (remaining == 0) {
            delete this;
        }
        return remaining;
    }

    STDMETHODIMP ActivateCompleted(IActivateAudioInterfaceAsyncOperation* operation) override {
        HRESULT activation_hr = E_FAIL;
        IUnknown* activated = nullptr;
        if (operation == nullptr) {
            activation_hr = E_POINTER;
        } else {
            const HRESULT result_hr = operation->GetActivateResult(&activation_hr, &activated);
            if (FAILED(result_hr)) {
                activation_hr = result_hr;
            }
        }

        IAudioClient* client = nullptr;
        if (SUCCEEDED(activation_hr) && activated != nullptr) {
            const HRESULT query_hr = activated->QueryInterface(IID_PPV_ARGS(&client));
            if (FAILED(query_hr)) {
                activation_hr = query_hr;
            }
        } else if (SUCCEEDED(activation_hr)) {
            activation_hr = E_NOINTERFACE;
        }
        if (activated != nullptr) {
            activated->Release();
        }

        const auto state = state_;
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->callback_received = true;
            state->activation_hr = activation_hr;
            if (ActivationCompletionDispositionFor(state->abandoned) ==
                ActivationCompletionDisposition::release_client) {
                if (client != nullptr) {
                    client->Release();
                }
            } else {
                state->audio_client = client;
            }
        }
        SetEvent(state->completed.get());
        return S_OK;
    }

private:
    std::atomic<ULONG> reference_count_{1};
    std::shared_ptr<ActivationState> state_;
};

}  // namespace

AudioClientHandle::~AudioClientHandle() { reset(); }

AudioClientHandle::AudioClientHandle(AudioClientHandle&& other) noexcept
    : value_(other.release()) {}

AudioClientHandle& AudioClientHandle::operator=(AudioClientHandle&& other) noexcept {
    if (this != &other) {
        reset(other.release());
    }
    return *this;
}

IAudioClient* AudioClientHandle::release() noexcept {
    IAudioClient* value = value_;
    value_ = nullptr;
    return value;
}

void AudioClientHandle::reset(IAudioClient* replacement) noexcept {
    if (value_ != nullptr) {
        value_->Release();
    }
    value_ = replacement;
}

ProcessIdParseResult ParseProcessId(std::wstring_view text) noexcept {
    if (text.empty()) {
        return {};
    }

    std::uint64_t value = 0;
    for (const wchar_t character : text) {
        if (character < L'0' || character > L'9') {
            return {};
        }
        const std::uint64_t digit = static_cast<std::uint64_t>(character - L'0');
        if (value > (UINT32_MAX - digit) / 10) {
            return {};
        }
        value = value * 10 + digit;
    }
    if (value == 0) {
        return {};
    }
    ProcessIdParseResult result;
    result.hr = S_OK;
    result.process_id = static_cast<DWORD>(value);
    return result;
}

namespace {

HRESULT ReadProcessCreationTime(HANDLE process, std::uint64_t* result) noexcept {
    if (process == nullptr || result == nullptr) {
        return E_INVALIDARG;
    }
    FILETIME created{};
    FILETIME exited{};
    FILETIME kernel{};
    FILETIME user{};
    if (!GetProcessTimes(process, &created, &exited, &kernel, &user)) {
        return HRESULT_FROM_WIN32(GetLastError());
    }
    ULARGE_INTEGER value{};
    value.LowPart = created.dwLowDateTime;
    value.HighPart = created.dwHighDateTime;
    *result = value.QuadPart;
    return S_OK;
}

HRESULT VerifyProcessCreationTime(HANDLE process, std::uint64_t expected) noexcept {
    if (expected == 0) {
        return S_OK;
    }
    std::uint64_t actual = 0;
    const HRESULT result = ReadProcessCreationTime(process, &actual);
    if (FAILED(result)) {
        return result;
    }
    return actual == expected ? S_OK : HRESULT_FROM_WIN32(ERROR_PROCESS_ABORTED);
}

}  // namespace

HRESULT ValidateTargetProcess(
    DWORD process_id,
    std::uint64_t expected_creation_time_100ns) noexcept {
    if (process_id == 0) {
        return E_INVALIDARG;
    }
    ScopedHandle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id));
    if (process.get() == nullptr) {
        return HRESULT_FROM_WIN32(GetLastError());
    }
    return VerifyProcessCreationTime(process.get(), expected_creation_time_100ns);
}

ScopedHandle OpenTargetProcessForMonitoring(
    DWORD process_id,
    std::uint64_t expected_creation_time_100ns,
    HRESULT* error) noexcept {
    if (error == nullptr || process_id == 0) {
        if (error != nullptr) {
            *error = E_INVALIDARG;
        }
        return ScopedHandle();
    }
    ScopedHandle process(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                                    FALSE, process_id));
    if (process.get() == nullptr) {
        *error = HRESULT_FROM_WIN32(GetLastError());
        return ScopedHandle();
    }
    *error = VerifyProcessCreationTime(process.get(), expected_creation_time_100ns);
    if (FAILED(*error)) {
        return ScopedHandle();
    }
    const TargetProcessWaitDisposition disposition =
        TargetProcessWaitDispositionFor(WaitForSingleObject(process.get(), 0));
    if (disposition == TargetProcessWaitDisposition::exited) {
        *error = HRESULT_FROM_WIN32(ERROR_PROCESS_ABORTED);
        return ScopedHandle();
    }
    if (disposition == TargetProcessWaitDisposition::wait_failed) {
        *error = HRESULT_FROM_WIN32(GetLastError());
        return ScopedHandle();
    }
    *error = S_OK;
    return process;
}

HRESULT CheckProcessLoopbackOSSupport() noexcept {
    using RtlGetVersionFunction = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
    const HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    const auto rtl_get_version = ntdll == nullptr
        ? nullptr
        : reinterpret_cast<RtlGetVersionFunction>(GetProcAddress(ntdll, "RtlGetVersion"));
    if (rtl_get_version == nullptr) {
        return HRESULT_FROM_WIN32(ERROR_OLD_WIN_VERSION);
    }

    RTL_OSVERSIONINFOW version{};
    version.dwOSVersionInfoSize = sizeof(version);
    if (rtl_get_version(&version) != 0 || version.dwMajorVersion < 10 ||
        version.dwBuildNumber < kMinimumSupportedBuild) {
        return HRESULT_FROM_WIN32(ERROR_OLD_WIN_VERSION);
    }
    return S_OK;
}

ActivationCompletionDisposition ActivationCompletionDispositionFor(
    bool activation_abandoned) noexcept {
    return activation_abandoned
        ? ActivationCompletionDisposition::release_client
        : ActivationCompletionDisposition::deliver_result;
}

ProcessLoopbackCaptureMetadata DescribeProcessLoopbackTarget(
    DWORD selected_root_process_id) noexcept {
    ProcessLoopbackCaptureMetadata metadata;
    metadata.selected_root_process_id = selected_root_process_id;
    return metadata;
}

TargetProcessWaitDisposition TargetProcessWaitDispositionFor(
    DWORD wait_result) noexcept {
    if (wait_result == WAIT_TIMEOUT) {
        return TargetProcessWaitDisposition::still_running;
    }
    if (wait_result == WAIT_OBJECT_0) {
        return TargetProcessWaitDisposition::exited;
    }
    return TargetProcessWaitDisposition::wait_failed;
}

ProcessLoopbackActivationResult ActivateProcessLoopback(
    DWORD target_process_id,
    DWORD timeout_ms,
    std::uint64_t expected_creation_time_100ns) noexcept {
    ProcessLoopbackActivationResult result;
    if (target_process_id == 0 || timeout_ms == 0) {
        result.hr = E_INVALIDARG;
        return result;
    }
    result.hr = CheckProcessLoopbackOSSupport();
    if (FAILED(result.hr)) {
        return result;
    }
    result.hr = ValidateTargetProcess(target_process_id, expected_creation_time_100ns);
    if (FAILED(result.hr)) {
        return result;
    }

    auto state = std::make_shared<ActivationState>();
    if (state->completed.get() == nullptr) {
        result.hr = HRESULT_FROM_WIN32(GetLastError());
        return result;
    }
    state->activation_params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    state->activation_params.ProcessLoopbackParams.ProcessLoopbackMode =
        PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
    state->activation_params.ProcessLoopbackParams.TargetProcessId = target_process_id;
    PropVariantInit(&state->activation_propvariant);
    state->activation_propvariant.vt = VT_BLOB;
    state->activation_propvariant.blob.cbSize = sizeof(state->activation_params);
    state->activation_propvariant.blob.pBlobData =
        reinterpret_cast<BYTE*>(&state->activation_params);

    auto* callback = new (std::nothrow) ActivationCompletionHandler(state);
    if (callback == nullptr) {
        result.hr = E_OUTOFMEMORY;
        return result;
    }

    IActivateAudioInterfaceAsyncOperation* operation = nullptr;
    const HRESULT submit_hr = ActivateAudioInterfaceAsync(
        VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
        __uuidof(IAudioClient),
        &state->activation_propvariant,
        callback,
        &operation);
    // ActivateAudioInterfaceAsync retains the callback when it accepts the request.
    callback->Release();
    if (FAILED(submit_hr)) {
        if (operation != nullptr) {
            operation->Release();
        }
        result.hr = submit_hr;
        return result;
    }

    const DWORD wait_result = WaitForSingleObject(state->completed.get(), timeout_ms);
    if (operation != nullptr) {
        operation->Release();
    }
    if (wait_result == WAIT_TIMEOUT) {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->abandoned = true;
        result.hr = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        result.timed_out = true;
        return result;
    }
    if (wait_result != WAIT_OBJECT_0) {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->abandoned = true;
        result.hr = HRESULT_FROM_WIN32(GetLastError());
        return result;
    }

    std::lock_guard<std::mutex> lock(state->mutex);
    result.hr = state->activation_hr;
    if (SUCCEEDED(result.hr) && state->audio_client != nullptr) {
        result.audio_client = AudioClientHandle(state->audio_client);
        state->audio_client = nullptr;
    } else if (SUCCEEDED(result.hr)) {
        result.hr = E_NOINTERFACE;
    }
    return result;
}

ProcessLoopbackCapture::ProcessLoopbackCapture() = default;
ProcessLoopbackCapture::~ProcessLoopbackCapture() { Stop(); }

void ProcessLoopbackCapture::SetError(HRESULT hresult, const wchar_t* context,
                                      bool activation_timed_out) {
    std::lock_guard<std::mutex> lock(mutex_);
    last_error_.hresult = hresult;
    last_error_.device_invalidated = IsDeviceInvalidated(hresult);
    last_error_.activation_timed_out = activation_timed_out;
    last_error_.message = std::wstring(context) + L": " + DescribeHresult(hresult);
}

bool ProcessLoopbackCapture::Start(
    ProcessLoopbackCaptureRequest request,
    ProcessLoopbackAudioBlockCallback callback) {
    if (!callback || request.target_process_id == 0 ||
        request.activation_timeout_ms == 0 ||
        request.polling_interval_ms == 0) {
        SetError(E_INVALIDARG, L"Invalid process loopback capture request");
        return false;
    }
    const HRESULT target_validation = ValidateTargetProcess(
        request.target_process_id,
        request.expected_process_creation_time_100ns);
    if (FAILED(target_validation)) {
        SetError(target_validation, L"Selected root process is unavailable before capture start");
        return false;
    }
    ScopedHandle started(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (started.get() == nullptr) {
        SetError(HRESULT_FROM_WIN32(GetLastError()), L"CreateEvent(started) failed");
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (worker_.joinable() || running_) {
            last_error_ = {E_UNEXPECTED, false, false, L"Process loopback capture is already active."};
            return false;
        }
        stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (stop_event_ == nullptr) {
            last_error_ = {HRESULT_FROM_WIN32(GetLastError()), false, false,
                           L"CreateEvent(stop) failed."};
            return false;
        }
        last_error_ = {};
        worker_ = std::thread(&ProcessLoopbackCapture::CaptureThread, this, request,
                              std::move(callback), started.get());
    }

    // Activation itself has a bounded timeout. This waits for its result or an
    // earlier setup failure; no unbounded system-audio fallback is possible.
    const DWORD wait_result = WaitForSingleObject(started.get(), request.activation_timeout_ms);
    if (wait_result != WAIT_OBJECT_0) {
        SetError(wait_result == WAIT_TIMEOUT ? HRESULT_FROM_WIN32(ERROR_TIMEOUT)
                                              : HRESULT_FROM_WIN32(GetLastError()),
                 L"Waiting for process loopback startup failed",
                 wait_result == WAIT_TIMEOUT);
        Stop();
        return false;
    }
    bool running = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        running = running_;
    }
    if (!running) {
        Stop();
    }
    return running;
}

void ProcessLoopbackCapture::Stop() {
    std::thread worker;
    HANDLE stop = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stop = stop_event_;
        if (!worker_.joinable()) {
            return;
        }
        if (stop != nullptr) {
            SetEvent(stop);
        }
        // A callback executes on this worker. Joining oneself terminates on
        // standard library implementations, so make callback Stop a safe,
        // asynchronous shutdown request. A control thread later joins it.
        if (worker_.get_id() == std::this_thread::get_id()) {
            return;
        }
        worker = std::move(worker_);
    }
    if (worker.joinable()) {
        worker.join();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (stop_event_ == stop) {
        CloseHandle(stop_event_);
        stop_event_ = nullptr;
    }
    running_ = false;
}

bool ProcessLoopbackCapture::is_running() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return running_;
}

ProcessLoopbackCaptureError ProcessLoopbackCapture::last_error() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return last_error_;
}

void ProcessLoopbackCapture::CaptureThread(
    ProcessLoopbackCaptureRequest request,
    ProcessLoopbackAudioBlockCallback callback,
    HANDLE started_event) {
    ScopedCoInitialize com;
    HRESULT target_process_error = S_OK;
    ScopedHandle target_process(
        OpenTargetProcessForMonitoring(
            request.target_process_id,
            request.expected_process_creation_time_100ns,
            &target_process_error));
    // Keep this validated handle alive for the complete activation and capture
    // lifetime. Windows cannot recycle the PID while this process object is
    // referenced, so the later virtual-endpoint activation cannot bind a new
    // process with the same numeric PID.
    AudioClientHandle client;
    ComPtr<IAudioCaptureClient> capture;
    WAVEFORMATEX capture_format{};
    capture_format.wFormatTag = WAVE_FORMAT_PCM;
    capture_format.nChannels = 2;
    capture_format.nSamplesPerSec = 44'100;
    capture_format.wBitsPerSample = 16;
    capture_format.nBlockAlign = static_cast<WORD>(
        capture_format.nChannels * capture_format.wBitsPerSample / 8U);
    capture_format.nAvgBytesPerSec =
        capture_format.nSamplesPerSec * capture_format.nBlockAlign;
    bool event_driven = true;
    bool started_client = false;
    HRESULT result = S_OK;
    auto fail = [&](HRESULT failure, const wchar_t* context, bool timed_out = false) {
        SetError(failure, context, timed_out);
        SetEvent(started_event);
    };

    if (FAILED(com.result())) {
        fail(com.result(), L"CoInitializeEx failed");
        return;
    }
    if (FAILED(target_process_error)) {
        fail(target_process_error, L"Selected root process exited before activation");
        return;
    }
    auto activation = ActivateProcessLoopback(
        request.target_process_id,
        request.activation_timeout_ms,
        request.expected_process_creation_time_100ns);
    if (!activation.succeeded()) {
        fail(activation.hr, L"Activating target-process loopback failed", activation.timed_out);
        return;
    }
    client = std::move(activation.audio_client);

    auto configure_client = [&](bool request_events) -> HRESULT {
        return client.get()->Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_LOOPBACK |
                AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                (request_events ? AUDCLNT_STREAMFLAGS_EVENTCALLBACK : 0),
            0,
            0,
            &capture_format,
            nullptr);
    };

    result = configure_client(true);
    if (FAILED(result)) {
        // Re-activate the same virtual process-loopback endpoint, never an
        // IMMDevice/all-system endpoint, before using bounded polling.
        client.reset();
        activation = ActivateProcessLoopback(
            request.target_process_id,
            request.activation_timeout_ms,
            request.expected_process_creation_time_100ns);
        if (activation.succeeded()) {
            client = std::move(activation.audio_client);
            result = configure_client(false);
            event_driven = false;
        } else {
            result = activation.hr;
        }
    }
    if (FAILED(result)) {
        fail(result, L"Initializing shared process-loopback capture failed", activation.timed_out);
        return;
    }

    const WORD block_align = capture_format.nBlockAlign;
    if (block_align == 0) {
        fail(E_FAIL, L"Process-loopback mix format has zero block alignment");
        return;
    }
    std::vector<std::uint8_t> format_bytes(
        reinterpret_cast<const std::uint8_t*>(&capture_format),
        reinterpret_cast<const std::uint8_t*>(&capture_format) +
            sizeof(capture_format));

    ScopedHandle audio_event(event_driven ? CreateEventW(nullptr, FALSE, FALSE, nullptr) : nullptr);
    if (event_driven) {
        if (audio_event.get() == nullptr) {
            fail(HRESULT_FROM_WIN32(GetLastError()), L"CreateEvent(audio) failed");
            return;
        }
        result = client.get()->SetEventHandle(audio_event.get());
        if (FAILED(result)) {
            fail(result, L"Setting process-loopback event handle failed");
            return;
        }
    }
    result = client.get()->GetService(
        __uuidof(IAudioCaptureClient),
        reinterpret_cast<void**>(capture.put()));
    if (FAILED(result)) {
        fail(result, L"Getting IAudioCaptureClient failed");
        return;
    }
    result = client.get()->Start();
    if (FAILED(result)) {
        fail(result, L"Starting process-loopback capture failed");
        return;
    }
    started_client = true;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        running_ = true;
    }
    SetEvent(started_event);

    auto drain_packets = [&]() -> HRESULT {
        UINT32 packet_frames = 0;
        HRESULT drain_hr = S_OK;
        while (SUCCEEDED(drain_hr = capture->GetNextPacketSize(&packet_frames)) && packet_frames != 0) {
            BYTE* data = nullptr;
            UINT32 frame_count = 0;
            DWORD flags = 0;
            UINT64 device_position = 0;
            UINT64 qpc_position = 0;
            drain_hr = capture->GetBuffer(&data, &frame_count, &flags,
                                          &device_position, &qpc_position);
            if (FAILED(drain_hr)) {
                break;
            }
            ProcessLoopbackAudioBlock block;
            block.capture_metadata = DescribeProcessLoopbackTarget(request.target_process_id);
            block.mix_format_bytes = format_bytes;
            block.frame_count = frame_count;
            block.device_position_frames = device_position;
            block.qpc_position = qpc_position;
            block.silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
            block.discontinuity = (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0;
            block.event_driven = event_driven;
            if (!block.silent && data != nullptr) {
                const std::size_t byte_count = static_cast<std::size_t>(frame_count) * block_align;
                block.bytes.assign(data, data + byte_count);
            }
            const HRESULT release_hr = capture->ReleaseBuffer(frame_count);
            if (FAILED(release_hr)) {
                return release_hr;
            }
            try {
                callback(std::move(block));
            } catch (...) {
                return E_FAIL;
            }
            packet_frames = 0;
        }
        return drain_hr;
    };

    HANDLE waits[] = {stop_event_, target_process.get(), audio_event.get()};
    bool capture_failed = false;
    while (true) {
        const DWORD waited = event_driven
            ? WaitForMultipleObjects(3, waits, FALSE, INFINITE)
            : WaitForMultipleObjects(2, waits, FALSE, request.polling_interval_ms);
        if (waited == WAIT_OBJECT_0) {
            break;
        }
        if (waited == WAIT_OBJECT_0 + 1) {
            SetError(HRESULT_FROM_WIN32(ERROR_PROCESS_ABORTED),
                     L"Selected root process exited during capture");
            capture_failed = true;
            break;
        }
        if ((event_driven && waited != WAIT_OBJECT_0 + 2) ||
            (!event_driven && waited != WAIT_TIMEOUT)) {
            SetError(HRESULT_FROM_WIN32(GetLastError()),
                     L"Waiting for process-loopback capture failed");
            capture_failed = true;
            break;
        }
        result = drain_packets();
        if (FAILED(result)) {
            SetError(result, L"Reading process-loopback packet failed");
            capture_failed = true;
            break;
        }
    }

    // A normal Stop drains packets queued before IAudioClient::Stop. If a read
    // already failed, do not attempt to invent a successful final packet.
    if (!capture_failed) {
        result = drain_packets();
        if (FAILED(result)) {
            SetError(result, L"Draining process-loopback packets failed");
        }
    }
    if (started_client) {
        const HRESULT stop_result = client.get()->Stop();
        if (FAILED(stop_result)) {
            SetError(stop_result, L"Stopping process-loopback capture failed");
        }
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        running_ = false;
    }
}

}  // namespace teams_recorder::process_loopback
