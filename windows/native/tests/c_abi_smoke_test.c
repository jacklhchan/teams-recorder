#include "recorder_native_bridge.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

_Static_assert(RECORDER_NATIVE_CAPTURE_SYSTEM_LOOPBACK == 0, "capture mode ABI changed");
_Static_assert(RECORDER_NATIVE_CAPTURE_MICROPHONE == 1, "capture mode ABI changed");
_Static_assert(RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK == 2, "capture mode ABI changed");
_Static_assert(RECORDER_NATIVE_STATE_STARTING == 4, "state ABI changed");
_Static_assert(RECORDER_NATIVE_STATE_STOPPING == 5, "state ABI changed");
_Static_assert(RECORDER_NATIVE_ENDPOINT_FLOW_RENDER == 0u, "render flow ABI changed");
_Static_assert(RECORDER_NATIVE_ENDPOINT_FLOW_CAPTURE == 1u, "capture flow ABI changed");
_Static_assert(RECORDER_NATIVE_ENDPOINT_DEFAULT_CONSOLE == 1u, "console default ABI changed");
_Static_assert(RECORDER_NATIVE_ENDPOINT_DEFAULT_MULTIMEDIA == 2u, "multimedia default ABI changed");
_Static_assert(RECORDER_NATIVE_ENDPOINT_DEFAULT_COMMUNICATIONS == 4u, "communications default ABI changed");
_Static_assert(sizeof(RecorderNativeStartOptions) == 32u, "x64 start options layout changed");
_Static_assert(offsetof(RecorderNativeStartOptions, output_path_utf8) == 8u, "output path offset changed");
_Static_assert(offsetof(RecorderNativeStartOptions, endpoint_id_utf8) == 16u, "endpoint ID offset changed");
_Static_assert(offsetof(RecorderNativeStartOptions, target_process_id) == 24u, "target PID offset changed");
_Static_assert(sizeof(RecorderNativeStats) == 96u, "x64 stats layout changed");
_Static_assert(offsetof(RecorderNativeStats, packets) == 32u, "packet counter offset changed");
_Static_assert(offsetof(RecorderNativeStats, peak) == 88u, "peak offset changed");

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
    RecorderNativeEndpointList* endpoint_list = (RecorderNativeEndpointList*)(uintptr_t)1;
    RecorderNativeStartOptions options;
    RecorderNativeStats stats = {0};
    uint32_t endpoint_count = 0;

    recorder_native_endpoint_list_destroy(NULL);

    if (!expect(strcmp(recorder_native_version(), "0.4.0") == 0, "version must be exported") ||
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
        !expect(recorder_native_enumerate_endpoints(NULL, &endpoint_list) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "endpoint enumerate(NULL) must reject the handle") ||
        !expect(endpoint_list == NULL, "failed endpoint enumerate must clear the output list") ||
        !expect(recorder_native_endpoint_list_get_count(NULL, &endpoint_count) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "endpoint count(NULL) must reject the list") ||
        !expect(recorder_native_endpoint_list_get(NULL, 0U, NULL, NULL, NULL, NULL) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "endpoint get(NULL) must reject its arguments") ||
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

    options = valid_options();
    options.target_process_id = 42U;
    if (!expect(recorder_native_start_with_options(bridge, &options) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "non-process capture must reject a target PID")) {
        recorder_native_destroy(bridge);
        return 1;
    }
    options = valid_options();
    options.mode = RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK;
    options.target_process_id = 42U;
    options.endpoint_id_utf8 = "endpoint-id";
    if (!expect(recorder_native_start_with_options(bridge, &options) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "process loopback must reject an endpoint ID") ||
        !expect(recorder_native_get_state(bridge) == RECORDER_NATIVE_STATE_READY,
                "rejected options must not start capture")) {
        recorder_native_destroy(bridge);
        return 1;
    }

    recorder_native_destroy(bridge);
    return 0;
}
