#include "recorder_native_bridge.h"

#if defined(_WIN32)
#include "capture_session.h"

#include <windows.h>
#endif

#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <string_view>
#include <utility>

struct RecorderNativeBridge {
    mutable std::mutex mutex;
    RecorderNativeState state = RECORDER_NATIVE_STATE_READY;
    RecorderNativeStats last_stats{};
    std::string last_error;
#if defined(_WIN32)
    std::unique_ptr<recorder::bridge::CaptureSession> session;
#endif
};

namespace {

constexpr char kVersion[] = "0.2.0";
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
        mode == RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK;
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
#endif

}  // namespace

extern "C" RecorderNativeBridge* recorder_native_create(void) {
    try {
        auto bridge = std::make_unique<RecorderNativeBridge>();
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
#endif

    delete bridge;
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
            !bridge->session) {
            SetErrorLocked(
                bridge,
                "Recorder cannot stop from its current state.");
            return RECORDER_NATIVE_INVALID_STATE;
        }
        bridge->state = RECORDER_NATIVE_STATE_STOPPING;
        session = bridge->session.get();
    }

    const RecorderNativeResult result = session->Stop();
    const RecorderNativeStats stats = session->stats();
    const std::string error = session->last_error();

    std::lock_guard<std::mutex> lock(bridge->mutex);
    bridge->last_stats = stats;
    bridge->session.reset();
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
    return bridge->state;
}

extern "C" RecorderNativeResult recorder_native_get_stats(
    const RecorderNativeBridge* bridge,
    RecorderNativeStats* stats) {
    if (bridge == nullptr || stats == nullptr ||
        stats->struct_size < sizeof(RecorderNativeStats)) {
        return RECORDER_NATIVE_INVALID_ARGUMENT;
    }

    std::lock_guard<std::mutex> lock(bridge->mutex);
#if defined(_WIN32)
    if (bridge->session) {
        *stats = bridge->session->stats();
        return RECORDER_NATIVE_OK;
    }
#endif
    *stats = bridge->last_stats;
    return RECORDER_NATIVE_OK;
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
