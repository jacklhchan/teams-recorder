#include "recorder_native_bridge.h"

#include <cstring>
#include <type_traits>

static_assert(std::is_standard_layout<RecorderNativeStartOptions>::value, "start options must remain C ABI safe");
static_assert(std::is_standard_layout<RecorderNativeStats>::value, "stats must remain C ABI safe");
static_assert(RECORDER_NATIVE_CAPTURE_SYSTEM_LOOPBACK == 0, "capture mode ABI value changed");
static_assert(RECORDER_NATIVE_CAPTURE_MICROPHONE == 1, "capture mode ABI value changed");
static_assert(RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK == 2, "capture mode ABI value changed");
static_assert(RECORDER_NATIVE_STATE_STARTING == 4, "state ABI value changed");
static_assert(RECORDER_NATIVE_STATE_STOPPING == 5, "state ABI value changed");

namespace {

bool Expect(bool condition) { return condition; }

RecorderNativeStartOptions ValidOptions() {
    RecorderNativeStartOptions options{};
    options.struct_size = sizeof(options);
    options.mode = RECORDER_NATIVE_CAPTURE_SYSTEM_LOOPBACK;
    options.output_path_utf8 = "contract-test-does-not-start.wav";
    return options;
}

}  // namespace

int main() {
    if (!Expect(std::strcmp(recorder_native_version(), "0.2.0") == 0) ||
        !Expect(recorder_native_start(nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) ||
        !Expect(recorder_native_start_with_options(nullptr, nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) ||
        !Expect(recorder_native_stop(nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) ||
        !Expect(recorder_native_get_stats(nullptr, nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) ||
        !Expect(recorder_native_get_state(nullptr) == RECORDER_NATIVE_STATE_FAULTED) ||
        !Expect(std::strstr(recorder_native_get_last_error(nullptr), "null") != nullptr)) {
        return 1;
    }

    RecorderNativeBridge* bridge = recorder_native_create();
    if (!Expect(bridge != nullptr)) { return 1; }

    RecorderNativeStats stats{};
    stats.struct_size = sizeof(stats);
    RecorderNativeStartOptions options = ValidOptions();
    const bool passed =
        Expect(recorder_native_get_state(bridge) == RECORDER_NATIVE_STATE_READY) &&
        Expect(recorder_native_start(bridge) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect(recorder_native_start_with_options(bridge, nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect(recorder_native_get_stats(bridge, nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect(recorder_native_get_stats(bridge, &stats) == RECORDER_NATIVE_OK) &&
        Expect(stats.struct_size == sizeof(stats)) &&
        Expect(stats.event_driven == 0U) &&
        Expect(stats.packets == 0U && stats.input_frames == 0U && stats.output_frames == 0U) &&
        Expect((options.struct_size = 0U, recorder_native_start_with_options(bridge, &options)) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect((options = ValidOptions(), options.output_path_utf8 = nullptr,
                recorder_native_start_with_options(bridge, &options)) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect((options = ValidOptions(), options.mode = static_cast<RecorderNativeCaptureMode>(99),
                recorder_native_start_with_options(bridge, &options)) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect(recorder_native_get_state(bridge) == RECORDER_NATIVE_STATE_READY);
    recorder_native_destroy(bridge);
    return passed ? 0 : 1;
}
