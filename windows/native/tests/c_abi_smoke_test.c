#include "recorder_native_bridge.h"

#include <stdio.h>
#include <string.h>

_Static_assert(RECORDER_NATIVE_CAPTURE_SYSTEM_LOOPBACK == 0, "capture mode ABI changed");
_Static_assert(RECORDER_NATIVE_CAPTURE_MICROPHONE == 1, "capture mode ABI changed");
_Static_assert(RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK == 2, "capture mode ABI changed");
_Static_assert(RECORDER_NATIVE_STATE_STARTING == 4, "state ABI changed");
_Static_assert(RECORDER_NATIVE_STATE_STOPPING == 5, "state ABI changed");

static int expect(int condition, const char* message) {
    if (!condition) {
        (void)fprintf(stderr, "%s\n", message);
        return 0;
    }
    return 1;
}

static RecorderNativeStartOptions valid_options(void) {
    RecorderNativeStartOptions options = {0};
    options.struct_size = (uint32_t)sizeof(options);
    options.mode = RECORDER_NATIVE_CAPTURE_SYSTEM_LOOPBACK;
    options.output_path_utf8 = "c-abi-contract-does-not-start.wav";
    return options;
}

int main(void) {
    RecorderNativeBridge* bridge;
    RecorderNativeStartOptions options;
    RecorderNativeStats stats = {0};

    if (!expect(recorder_native_version() != NULL, "version must be exported") ||
        !expect(recorder_native_start(NULL) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "legacy start(NULL) must reject the handle") ||
        !expect(recorder_native_start_with_options(NULL, NULL) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "options start(NULL) must reject the handle") ||
        !expect(recorder_native_stop(NULL) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "stop(NULL) must reject the handle") ||
        !expect(recorder_native_get_stats(NULL, NULL) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "get_stats(NULL) must reject the handle") ||
        !expect(recorder_native_get_state(NULL) == RECORDER_NATIVE_STATE_FAULTED,
                "get_state(NULL) must be faulted") ||
        !expect(strstr(recorder_native_get_last_error(NULL), "null") != NULL,
                "NULL-handle error must be readable")) {
        return 1;
    }

    bridge = recorder_native_create();
    if (!expect(bridge != NULL, "create must return a handle")) { return 1; }

    stats.struct_size = (uint32_t)sizeof(stats);
    options = valid_options();
    if (!expect(recorder_native_start(bridge) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "legacy start must require an output path") ||
        !expect(recorder_native_start_with_options(bridge, NULL) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "NULL options must be rejected") ||
        !expect(recorder_native_get_stats(bridge, NULL) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "NULL stats must be rejected") ||
        !expect(recorder_native_get_stats(bridge, &stats) == RECORDER_NATIVE_OK,
                "fresh stats must be available") ||
        !expect(stats.struct_size == sizeof(stats) && stats.packets == 0U && stats.output_frames == 0U,
                "fresh stats must be zeroed") ||
        !expect((options.struct_size = 0U, recorder_native_start_with_options(bridge, &options)) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "wrong options size must be rejected")) {
        recorder_native_destroy(bridge);
        return 1;
    }

    options = valid_options();
    options.output_path_utf8 = NULL;
    if (!expect(recorder_native_start_with_options(bridge, &options) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "missing output path must be rejected")) {
        recorder_native_destroy(bridge);
        return 1;
    }
    options = valid_options();
    options.mode = (RecorderNativeCaptureMode)99;
    if (!expect(recorder_native_start_with_options(bridge, &options) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "unknown capture mode must be rejected") ||
        !expect(recorder_native_get_state(bridge) == RECORDER_NATIVE_STATE_READY,
                "invalid options must not start capture")) {
        recorder_native_destroy(bridge);
        return 1;
    }

    recorder_native_destroy(bridge);
    return 0;
}
