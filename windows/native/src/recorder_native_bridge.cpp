#include "recorder_native_bridge.h"

#if defined(_WIN32)
#include "capture_session.h"
#include "mixed_capture_session.h"
#include "wasapi_capture.h"

#include <mfapi.h>
#include <windows.h>
#endif

#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

#if defined(_WIN32)
class MediaFoundationRuntime final {
public:
    MediaFoundationRuntime() = default;

    HRESULT Start() noexcept {
        const HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
        if (SUCCEEDED(hr)) {
            started_ = true;
        }
        return hr;
    }

    void Shutdown() noexcept {
        if (started_) {
            // All capture sessions and their sink writers are explicitly
            // destroyed before this call (see recorder_native_destroy).
            MFShutdown();
            started_ = false;
        }
    }

    ~MediaFoundationRuntime() { Shutdown(); }

    MediaFoundationRuntime(const MediaFoundationRuntime&) = delete;
    MediaFoundationRuntime& operator=(const MediaFoundationRuntime&) = delete;

private:
    bool started_ = false;
};
#endif

}  // namespace

struct RecorderNativeBridge {
    mutable std::mutex mutex;
    RecorderNativeState state = RECORDER_NATIVE_STATE_READY;
    RecorderNativeStats last_stats{};
    mutable std::string last_error;
#if defined(_WIN32)
    MediaFoundationRuntime media_foundation;
    std::unique_ptr<recorder::bridge::CaptureSession> session;
    std::unique_ptr<recorder::bridge::MixedCaptureSession> mixed_session;
#endif
};

#if defined(_WIN32)
struct RecorderNativeEndpointEntry {
    std::uint32_t flow = RECORDER_NATIVE_ENDPOINT_FLOW_RENDER;
    std::uint32_t default_flags = 0;
    std::string endpoint_id;
    std::string friendly_name;
};
#endif

struct RecorderNativeEndpointList {
#if defined(_WIN32)
    std::vector<RecorderNativeEndpointEntry> entries;
#endif
};

namespace {

constexpr char kVersion[] = "0.5.0";
constexpr char kInvalidHandleError[] = "RecorderNativeBridge handle is null.";

RecorderNativeStats EmptyStats(RecorderNativeCaptureMode mode) {
    RecorderNativeStats stats{};
    stats.struct_size = sizeof(stats);
    stats.mode = mode;
    stats.output_sample_rate = 48'000;
    stats.output_channels = 2;
    return stats;
}

void SetErrorLocked(RecorderNativeBridge* bridge, std::string message) {
    bridge->last_error = std::move(message);
}

bool IsValidMode(RecorderNativeCaptureMode mode) {
    return mode == RECORDER_NATIVE_CAPTURE_SYSTEM_LOOPBACK ||
        mode == RECORDER_NATIVE_CAPTURE_MICROPHONE ||
        mode == RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK ||
        mode == RECORDER_NATIVE_CAPTURE_MIXED;
}

RecorderNativeResult Reject(
    RecorderNativeBridge* bridge,
    RecorderNativeResult result,
    const char* message) {
    if (bridge != nullptr) {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        SetErrorLocked(bridge, message);
    }
    return result;
}

#if defined(_WIN32)
bool Utf8ToWide(const char* value, std::wstring* result) {
    if (value == nullptr || result == nullptr) {
        return false;
    }

    const std::size_t length = std::strlen(value);
    if (length > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        return false;
    }
    if (length == 0) {
        result->clear();
        return true;
    }

    const int required = MultiByteToWideChar(
        CP_UTF8,
        MB_ERR_INVALID_CHARS,
        value,
        static_cast<int>(length),
        nullptr,
        0);
    if (required <= 0) {
        return false;
    }

    result->assign(static_cast<std::size_t>(required), L'\0');
    return MultiByteToWideChar(
               CP_UTF8,
               MB_ERR_INVALID_CHARS,
               value,
               static_cast<int>(length),
               result->data(),
               required) == required;
}

bool WideToUtf8(const std::wstring& value, std::string* result) {
    if (result == nullptr) {
        return false;
    }
    if (value.empty()) {
        result->clear();
        return true;
    }
    if (value.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        return false;
    }

    const int required = WideCharToMultiByte(
        CP_UTF8,
        WC_ERR_INVALID_CHARS,
        value.data(),
        static_cast<int>(value.size()),
        nullptr,
        0,
        nullptr,
        nullptr);
    if (required <= 0) {
        return false;
    }

    result->assign(static_cast<std::size_t>(required), '\0');
    return WideCharToMultiByte(
               CP_UTF8,
               WC_ERR_INVALID_CHARS,
               value.data(),
               static_cast<int>(value.size()),
               result->data(),
               required,
               nullptr,
               nullptr) == required;
}
#endif

}  // namespace

extern "C" RecorderNativeBridge* recorder_native_create(void) {
    try {
        auto bridge = std::make_unique<RecorderNativeBridge>();
#if defined(_WIN32)
        if (FAILED(bridge->media_foundation.Start())) {
            return nullptr;
        }
#endif
        bridge->last_stats =
            EmptyStats(RECORDER_NATIVE_CAPTURE_SYSTEM_LOOPBACK);
        return bridge.release();
    } catch (const std::bad_alloc&) {
        return nullptr;
    }
}

extern "C" void recorder_native_destroy(RecorderNativeBridge* bridge) {
    if (bridge == nullptr) {
        return;
    }

#if defined(_WIN32)
    bool should_stop = false;
    {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        should_stop = bridge->state == RECORDER_NATIVE_STATE_RECORDING;
    }
    if (should_stop) {
        (void)recorder_native_stop(bridge);
    }

    // A failed or interrupted start can leave a session allocated even when
    // the public state is no longer RECORDING.  Drop every session before
    // MFShutdown so writer/sink destruction cannot touch a shut-down runtime.
    {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        bridge->session.reset();
        bridge->mixed_session.reset();
    }
    bridge->media_foundation.Shutdown();
#endif

    delete bridge;
}

extern "C" RecorderNativeResult recorder_native_start_mixed(
    RecorderNativeBridge* bridge,
    const RecorderNativeMixedStartOptions* options) {
    if (bridge == nullptr) return RECORDER_NATIVE_INVALID_ARGUMENT;
    if (options == nullptr || options->struct_size < sizeof(RecorderNativeMixedStartOptions)) {
        return Reject(bridge, RECORDER_NATIVE_INVALID_ARGUMENT, "RecorderNativeMixedStartOptions has an invalid struct_size.");
    }
    if (options->output_path_utf8 == nullptr || options->output_path_utf8[0] == '\0' ||
        options->reserved != 0 || options->aac_bitrate_bps < 64000 || options->aac_bitrate_bps > 320000) {
        return Reject(bridge, RECORDER_NATIVE_INVALID_ARGUMENT, "Mixed capture requires a .m4a path, zero reserved field, and AAC bitrate from 64000 to 320000.");
    }
#if !defined(_WIN32)
    return Reject(bridge, RECORDER_NATIVE_NOT_IMPLEMENTED, "Native audio capture is implemented only on Windows.");
#else
    std::wstring output;
    std::wstring render;
    std::wstring microphone;
    if (!Utf8ToWide(options->output_path_utf8, &output) ||
        (options->render_endpoint_id_utf8 != nullptr && !Utf8ToWide(options->render_endpoint_id_utf8, &render)) ||
        (options->microphone_endpoint_id_utf8 != nullptr && !Utf8ToWide(options->microphone_endpoint_id_utf8, &microphone))) {
        return Reject(bridge, RECORDER_NATIVE_INVALID_ARGUMENT, "A mixed-capture path or endpoint ID is not valid UTF-8.");
    }
    if (output.size() < 4 || _wcsicmp(output.c_str() + output.size() - 4, L".m4a") != 0) {
        return Reject(bridge, RECORDER_NATIVE_INVALID_ARGUMENT, "Mixed capture output must use the .m4a extension.");
    }
    recorder::bridge::MixedCaptureSessionConfig config;
    config.output_path = output;
    config.render_endpoint_id = std::move(render);
    config.microphone_endpoint_id = std::move(microphone);
    config.aac_bitrate_bps = options->aac_bitrate_bps;
    RecorderNativeState previous = RECORDER_NATIVE_STATE_READY;
    {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        if (bridge->state != RECORDER_NATIVE_STATE_READY && bridge->state != RECORDER_NATIVE_STATE_STOPPED) {
            SetErrorLocked(bridge, "Recorder cannot start from its current state.");
            return RECORDER_NATIVE_INVALID_STATE;
        }
        previous = bridge->state;
        bridge->state = RECORDER_NATIVE_STATE_STARTING;
        bridge->last_error.clear();
        bridge->last_stats = EmptyStats(RECORDER_NATIVE_CAPTURE_MIXED);
    }
    try {
        auto session = std::make_unique<recorder::bridge::MixedCaptureSession>();
        const RecorderNativeResult result = session->Start(std::move(config));
        std::lock_guard<std::mutex> lock(bridge->mutex);
        bridge->last_stats = session->stats();
        if (result != RECORDER_NATIVE_OK) {
            bridge->state = previous;
            SetErrorLocked(bridge, session->last_error());
            return result;
        }
        bridge->mixed_session = std::move(session);
        bridge->state = RECORDER_NATIVE_STATE_RECORDING;
        return RECORDER_NATIVE_OK;
    } catch (const std::bad_alloc&) {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        bridge->state = previous;
        SetErrorLocked(bridge, "Allocating the mixed capture session failed.");
        return RECORDER_NATIVE_INTERNAL_ERROR;
    } catch (...) {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        bridge->state = previous;
        SetErrorLocked(bridge, "Starting mixed capture failed unexpectedly.");
        return RECORDER_NATIVE_INTERNAL_ERROR;
    }
#endif
}

extern "C" RecorderNativeResult recorder_native_set_microphone_muted(
    RecorderNativeBridge* bridge,
    std::uint32_t muted) {
    if (bridge == nullptr) {
        return RECORDER_NATIVE_INVALID_ARGUMENT;
    }
    if (muted > 1U) {
        return Reject(
            bridge,
            RECORDER_NATIVE_INVALID_ARGUMENT,
            "Microphone muted state must be 0 or 1.");
    }

#if !defined(_WIN32)
    return Reject(
        bridge,
        RECORDER_NATIVE_NOT_IMPLEMENTED,
        "Native audio capture is implemented only on Windows.");
#else
    std::lock_guard<std::mutex> lock(bridge->mutex);
    if (bridge->state != RECORDER_NATIVE_STATE_RECORDING ||
        !bridge->mixed_session) {
        SetErrorLocked(
            bridge,
            "Microphone mute is available only while mixed capture is recording.");
        return RECORDER_NATIVE_INVALID_STATE;
    }

    const RecorderNativeResult result =
        bridge->mixed_session->SetMicrophoneMuted(muted != 0U);
    if (result != RECORDER_NATIVE_OK) {
        SetErrorLocked(bridge, bridge->mixed_session->last_error());
    } else {
        bridge->last_error.clear();
    }
    return result;
#endif
}

extern "C" RecorderNativeResult recorder_native_start(
    RecorderNativeBridge* bridge) {
    if (bridge == nullptr) {
        return RECORDER_NATIVE_INVALID_ARGUMENT;
    }
    return Reject(
        bridge,
        RECORDER_NATIVE_INVALID_ARGUMENT,
        "Start options and an output path are required.");
}

extern "C" RecorderNativeResult recorder_native_start_with_options(
    RecorderNativeBridge* bridge,
    const RecorderNativeStartOptions* options) {
    if (bridge == nullptr) {
        return RECORDER_NATIVE_INVALID_ARGUMENT;
    }
    if (options == nullptr ||
        options->struct_size < sizeof(RecorderNativeStartOptions)) {
        return Reject(
            bridge,
            RECORDER_NATIVE_INVALID_ARGUMENT,
            "RecorderNativeStartOptions has an invalid struct_size.");
    }
    if (!IsValidMode(options->mode)) {
        return Reject(
            bridge,
            RECORDER_NATIVE_INVALID_ARGUMENT,
            "The requested capture mode is invalid.");
    }
    if (options->mode == RECORDER_NATIVE_CAPTURE_MIXED) {
        return Reject(bridge, RECORDER_NATIVE_INVALID_ARGUMENT,
            "Use recorder_native_start_mixed for mixed M4A capture.");
    }
    if (options->output_path_utf8 == nullptr ||
        options->output_path_utf8[0] == '\0') {
        return Reject(
            bridge,
            RECORDER_NATIVE_INVALID_ARGUMENT,
            "A non-empty UTF-8 output path is required.");
    }
    if (options->reserved != 0) {
        return Reject(
            bridge,
            RECORDER_NATIVE_INVALID_ARGUMENT,
            "RecorderNativeStartOptions.reserved must be zero.");
    }
    if (options->mode == RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK &&
        options->target_process_id == 0) {
        return Reject(
            bridge,
            RECORDER_NATIVE_INVALID_ARGUMENT,
            "Process-loopback capture requires a non-zero target PID.");
    }
    if (options->mode == RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK &&
        options->endpoint_id_utf8 != nullptr && options->endpoint_id_utf8[0] != '\0') {
        return Reject(
            bridge,
            RECORDER_NATIVE_INVALID_ARGUMENT,
            "Process-loopback capture does not accept an endpoint ID.");
    }
    if (options->mode != RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK &&
        options->target_process_id != 0) {
        return Reject(
            bridge,
            RECORDER_NATIVE_INVALID_ARGUMENT,
            "Only process-loopback capture accepts a target PID.");
    }

#if !defined(_WIN32)
    return Reject(
        bridge,
        RECORDER_NATIVE_NOT_IMPLEMENTED,
        "Native audio capture is implemented only on Windows.");
#else
    recorder::bridge::CaptureSessionConfig config;
    config.mode = options->mode;
    std::wstring output_path;
    if (!Utf8ToWide(options->output_path_utf8, &output_path)) {
        return Reject(
            bridge,
            RECORDER_NATIVE_INVALID_ARGUMENT,
            "The output path is not valid UTF-8.");
    }
    config.output_path = std::move(output_path);
    if (options->endpoint_id_utf8 != nullptr &&
        !Utf8ToWide(options->endpoint_id_utf8, &config.endpoint_id)) {
        return Reject(
            bridge,
            RECORDER_NATIVE_INVALID_ARGUMENT,
            "The endpoint ID is not valid UTF-8.");
    }
    config.target_process_id = options->target_process_id;

    RecorderNativeState previous_state = RECORDER_NATIVE_STATE_READY;
    {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        if (bridge->state != RECORDER_NATIVE_STATE_READY &&
            bridge->state != RECORDER_NATIVE_STATE_STOPPED) {
            SetErrorLocked(
                bridge,
                bridge->state == RECORDER_NATIVE_STATE_RECORDING
                    ? "Recorder is already recording."
                    : "Recorder cannot start from its current state.");
            return RECORDER_NATIVE_INVALID_STATE;
        }
        previous_state = bridge->state;
        bridge->state = RECORDER_NATIVE_STATE_STARTING;
        bridge->last_error.clear();
        bridge->last_stats = EmptyStats(options->mode);
    }

    try {
        auto session = std::make_unique<recorder::bridge::CaptureSession>();
        const RecorderNativeResult result = session->Start(std::move(config));
        std::lock_guard<std::mutex> lock(bridge->mutex);
        bridge->last_stats = session->stats();
        if (result != RECORDER_NATIVE_OK) {
            bridge->state = previous_state;
            SetErrorLocked(bridge, session->last_error());
            return result;
        }
        bridge->session = std::move(session);
        bridge->state = RECORDER_NATIVE_STATE_RECORDING;
        return RECORDER_NATIVE_OK;
    } catch (const std::bad_alloc&) {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        bridge->state = previous_state;
        SetErrorLocked(bridge, "Allocating the native capture session failed.");
        return RECORDER_NATIVE_INTERNAL_ERROR;
    } catch (...) {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        bridge->state = previous_state;
        SetErrorLocked(
            bridge,
            "Starting the native capture session failed unexpectedly.");
        return RECORDER_NATIVE_INTERNAL_ERROR;
    }
#endif
}

extern "C" RecorderNativeResult recorder_native_stop(
    RecorderNativeBridge* bridge) {
    if (bridge == nullptr) {
        return RECORDER_NATIVE_INVALID_ARGUMENT;
    }

#if !defined(_WIN32)
    std::lock_guard<std::mutex> lock(bridge->mutex);
    if (bridge->state == RECORDER_NATIVE_STATE_READY ||
        bridge->state == RECORDER_NATIVE_STATE_STOPPED) {
        bridge->last_error.clear();
        return RECORDER_NATIVE_OK;
    }
    SetErrorLocked(bridge, "Recorder cannot stop from its current state.");
    return RECORDER_NATIVE_INVALID_STATE;
#else
    recorder::bridge::CaptureSession* session = nullptr;
    {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        if (bridge->state == RECORDER_NATIVE_STATE_READY ||
            bridge->state == RECORDER_NATIVE_STATE_STOPPED) {
            bridge->last_error.clear();
            return RECORDER_NATIVE_OK;
        }
        if (bridge->state != RECORDER_NATIVE_STATE_RECORDING ||
            (!bridge->session && !bridge->mixed_session)) {
            SetErrorLocked(
                bridge,
                "Recorder cannot stop from its current state.");
            return RECORDER_NATIVE_INVALID_STATE;
        }
        bridge->state = RECORDER_NATIVE_STATE_STOPPING;
        session = bridge->session.get();
    }
    RecorderNativeResult result = RECORDER_NATIVE_OK;
    RecorderNativeStats stats{};
    std::string error;
    if (session != nullptr) {
        result = session->Stop(); stats = session->stats(); error = session->last_error();
    } else {
        recorder::bridge::MixedCaptureSession* mixed = nullptr;
        { std::lock_guard<std::mutex> lock(bridge->mutex); mixed = bridge->mixed_session.get(); }
        result = mixed->Stop(); stats = mixed->stats(); error = mixed->last_error();
    }

    std::lock_guard<std::mutex> lock(bridge->mutex);
    bridge->last_stats = stats;
    bridge->session.reset();
    bridge->mixed_session.reset();
    if (result == RECORDER_NATIVE_OK) {
        bridge->state = RECORDER_NATIVE_STATE_STOPPED;
        bridge->last_error.clear();
    } else {
        bridge->state = RECORDER_NATIVE_STATE_FAULTED;
        SetErrorLocked(bridge, error);
    }
    return result;
#endif
}

extern "C" RecorderNativeState recorder_native_get_state(
    const RecorderNativeBridge* bridge) {
    if (bridge == nullptr) {
        return RECORDER_NATIVE_STATE_FAULTED;
    }
    std::lock_guard<std::mutex> lock(bridge->mutex);
#if defined(_WIN32)
    if (bridge->state == RECORDER_NATIVE_STATE_RECORDING && (bridge->session || bridge->mixed_session)) {
        const RecorderNativeResult health = bridge->session ? bridge->session->health_result() : bridge->mixed_session->health_result();
        if (health != RECORDER_NATIVE_OK) {
            const std::string session_error = bridge->session ? bridge->session->last_error() : bridge->mixed_session->last_error();
            if (!session_error.empty()) {
                bridge->last_error = session_error;
            }
            return RECORDER_NATIVE_STATE_FAULTED;
        }
    }
#endif
    return bridge->state;
}

extern "C" RecorderNativeResult recorder_native_get_stats(
    const RecorderNativeBridge* bridge,
    RecorderNativeStats* stats) {
    if (bridge == nullptr || stats == nullptr ||
        stats->struct_size < RECORDER_NATIVE_STATS_V1_SIZE) {
        return RECORDER_NATIVE_INVALID_ARGUMENT;
    }
    const std::uint32_t caller_size = stats->struct_size;
    const auto copy_stats = [stats, caller_size](const RecorderNativeStats& source) {
        const std::size_t bytes = caller_size < sizeof(RecorderNativeStats)
            ? caller_size : sizeof(RecorderNativeStats);
        std::memcpy(stats, &source, bytes);
        // struct_size describes the caller-owned buffer, not the native
        // implementation's newest layout. This keeps v1 callers stable.
        stats->struct_size = caller_size;
    };

    std::lock_guard<std::mutex> lock(bridge->mutex);
#if defined(_WIN32)
    if (bridge->session) {
        copy_stats(bridge->session->stats());
        const RecorderNativeResult health = bridge->session->health_result();
        if (health != RECORDER_NATIVE_OK) {
            const std::string session_error = bridge->session->last_error();
            if (!session_error.empty()) {
                bridge->last_error = session_error;
            }
            return health;
        }
        return RECORDER_NATIVE_OK;
    }
    if (bridge->mixed_session) {
        copy_stats(bridge->mixed_session->stats());
        const RecorderNativeResult health = bridge->mixed_session->health_result();
        if (health != RECORDER_NATIVE_OK) {
            const std::string session_error = bridge->mixed_session->last_error();
            if (!session_error.empty()) bridge->last_error = session_error;
            return health;
        }
        return RECORDER_NATIVE_OK;
    }
#endif
    copy_stats(bridge->last_stats);
    return RECORDER_NATIVE_OK;
}

extern "C" RecorderNativeResult recorder_native_enumerate_endpoints(
    RecorderNativeBridge* bridge,
    RecorderNativeEndpointList** out_list) {
    if (out_list == nullptr) {
        return RECORDER_NATIVE_INVALID_ARGUMENT;
    }
    *out_list = nullptr;
    if (bridge == nullptr) {
        return RECORDER_NATIVE_INVALID_ARGUMENT;
    }

#if !defined(_WIN32)
    return Reject(
        bridge,
        RECORDER_NATIVE_NOT_IMPLEMENTED,
        "Endpoint enumeration is implemented only on Windows.");
#else
    std::vector<recorder::audio::EndpointInfo> endpoints;
    recorder::audio::CaptureError capture_error;
    const HRESULT enumeration_result =
        recorder::audio::WasapiCapture::EnumerateEndpoints(&endpoints, &capture_error);
    if (FAILED(enumeration_result)) {
        std::string error_text;
        if (!WideToUtf8(capture_error.message, &error_text) || error_text.empty()) {
            error_text = "Enumerating active audio endpoints failed.";
        }
        return Reject(bridge, RECORDER_NATIVE_CAPTURE_ERROR, error_text.c_str());
    }

    try {
        auto list = std::make_unique<RecorderNativeEndpointList>();
        list->entries.reserve(endpoints.size());
        for (const auto& endpoint : endpoints) {
            RecorderNativeEndpointEntry entry;
            entry.flow = endpoint.flow == recorder::audio::EndpointFlow::Render
                ? RECORDER_NATIVE_ENDPOINT_FLOW_RENDER
                : RECORDER_NATIVE_ENDPOINT_FLOW_CAPTURE;
            entry.default_flags = endpoint.default_flags;
            if (!WideToUtf8(endpoint.endpoint_id, &entry.endpoint_id) ||
                !WideToUtf8(endpoint.friendly_name, &entry.friendly_name)) {
                return Reject(
                    bridge,
                    RECORDER_NATIVE_INTERNAL_ERROR,
                    "Converting an audio endpoint name or ID to UTF-8 failed.");
            }
            list->entries.push_back(std::move(entry));
        }
        *out_list = list.release();
        return RECORDER_NATIVE_OK;
    } catch (const std::bad_alloc&) {
        return Reject(
            bridge,
            RECORDER_NATIVE_INTERNAL_ERROR,
            "Allocating the audio endpoint snapshot failed.");
    } catch (...) {
        return Reject(
            bridge,
            RECORDER_NATIVE_INTERNAL_ERROR,
            "Enumerating audio endpoints failed unexpectedly.");
    }
#endif
}

extern "C" void recorder_native_endpoint_list_destroy(
    RecorderNativeEndpointList* list) {
    delete list;
}

extern "C" RecorderNativeResult recorder_native_endpoint_list_get_count(
    const RecorderNativeEndpointList* list,
    uint32_t* out_count) {
    if (list == nullptr || out_count == nullptr) {
        return RECORDER_NATIVE_INVALID_ARGUMENT;
    }
#if defined(_WIN32)
    if (list->entries.size() > std::numeric_limits<uint32_t>::max()) {
        *out_count = 0;
        return RECORDER_NATIVE_INTERNAL_ERROR;
    }
    *out_count = static_cast<uint32_t>(list->entries.size());
#else
    *out_count = 0;
#endif
    return RECORDER_NATIVE_OK;
}

extern "C" RecorderNativeResult recorder_native_endpoint_list_get(
    const RecorderNativeEndpointList* list,
    uint32_t index,
    uint32_t* out_flow,
    uint32_t* out_default_flags,
    const char** out_endpoint_id_utf8,
    const char** out_friendly_name_utf8) {
    if (out_flow != nullptr) {
        *out_flow = 0;
    }
    if (out_default_flags != nullptr) {
        *out_default_flags = 0;
    }
    if (out_endpoint_id_utf8 != nullptr) {
        *out_endpoint_id_utf8 = nullptr;
    }
    if (out_friendly_name_utf8 != nullptr) {
        *out_friendly_name_utf8 = nullptr;
    }
    if (list == nullptr || out_flow == nullptr || out_default_flags == nullptr ||
        out_endpoint_id_utf8 == nullptr || out_friendly_name_utf8 == nullptr) {
        return RECORDER_NATIVE_INVALID_ARGUMENT;
    }
#if !defined(_WIN32)
    (void)index;
    return RECORDER_NATIVE_NOT_IMPLEMENTED;
#else
    if (index >= list->entries.size()) {
        return RECORDER_NATIVE_INVALID_ARGUMENT;
    }
    const RecorderNativeEndpointEntry& entry = list->entries[index];
    *out_flow = entry.flow;
    *out_default_flags = entry.default_flags;
    *out_endpoint_id_utf8 = entry.endpoint_id.c_str();
    *out_friendly_name_utf8 = entry.friendly_name.c_str();
    return RECORDER_NATIVE_OK;
#endif
}

extern "C" const char* recorder_native_get_last_error(
    const RecorderNativeBridge* bridge) {
    if (bridge == nullptr) {
        return kInvalidHandleError;
    }
    std::lock_guard<std::mutex> lock(bridge->mutex);
    return bridge->last_error.c_str();
}

extern "C" const char* recorder_native_version(void) {
    return kVersion;
}
