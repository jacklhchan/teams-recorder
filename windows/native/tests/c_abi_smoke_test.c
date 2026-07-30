#include "recorder_native_bridge.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

_Static_assert(RECORDER_NATIVE_CAPTURE_SYSTEM_LOOPBACK == 0, "capture mode ABI changed");
_Static_assert(RECORDER_NATIVE_CAPTURE_MICROPHONE == 1, "capture mode ABI changed");
_Static_assert(RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK == 2, "capture mode ABI changed");
_Static_assert(RECORDER_NATIVE_CAPTURE_MIXED == 3, "mixed capture mode ABI changed");
_Static_assert(RECORDER_NATIVE_CAPTURE_SELECTED_APP_MIXED == 4, "selected-audio capture mode ABI changed");
_Static_assert(RECORDER_NATIVE_SELECTED_AUDIO_SYSTEM_LOOPBACK == 0, "selected-audio system source ABI changed");
_Static_assert(RECORDER_NATIVE_SELECTED_AUDIO_PROCESS_TREE_LOOPBACK == 1, "selected-audio process-tree source ABI changed");
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
_Static_assert(sizeof(RecorderNativeStats) == 192u, "x64 stats layout changed");
_Static_assert(offsetof(RecorderNativeStats, packets) == 32u, "packet counter offset changed");
_Static_assert(offsetof(RecorderNativeStats, peak) == 88u, "peak offset changed");
_Static_assert(offsetof(RecorderNativeStats, render_drift_corrections) == 96u, "timeline stats must be additive");
_Static_assert(RECORDER_NATIVE_STATS_V1_SIZE == 96u, "v1 stats prefix changed");
_Static_assert(sizeof(RecorderNativeSelectedAudioStartOptions) == 56u, "x64 selected-audio options layout changed");
_Static_assert(offsetof(RecorderNativeSelectedAudioStartOptions, output_path_utf8) == 8u, "selected-audio output path offset changed");
_Static_assert(offsetof(RecorderNativeSelectedAudioStartOptions, render_endpoint_id_utf8) == 16u, "selected-audio render endpoint offset changed");
_Static_assert(offsetof(RecorderNativeSelectedAudioStartOptions, microphone_endpoint_id_utf8) == 24u, "selected-audio microphone offset changed");
_Static_assert(offsetof(RecorderNativeSelectedAudioStartOptions, target_process_id) == 32u, "selected-audio target PID offset changed");
_Static_assert(offsetof(RecorderNativeSelectedAudioStartOptions, expected_process_creation_time_100ns) == 48u, "selected-audio creation time offset changed");

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

static RecorderNativeSelectedAudioStartOptions valid_selected_audio_options(void) {
    RecorderNativeSelectedAudioStartOptions options = {0};
    options.struct_size = (uint32_t)sizeof(options);
    options.audio_source = RECORDER_NATIVE_SELECTED_AUDIO_PROCESS_TREE_LOOPBACK;
    options.output_path_utf8 = "c-abi-selected-audio-contract.m4a";
    options.target_process_id = 42U;
    options.included_process_tree = 1U;
    options.expected_process_creation_time_100ns = 1U;
    options.aac_bitrate_bps = 128000U;
    return options;
}

int main(void) {
    RecorderNativeBridge* bridge;
    RecorderNativeEndpointList* endpoint_list = (RecorderNativeEndpointList*)(uintptr_t)1;
    RecorderNativeStartOptions options;
    RecorderNativeSelectedAudioStartOptions selected;
    RecorderNativeStats stats = {0};
    RecorderNativeStats legacy_stats = {0};
    uint32_t endpoint_count = 0;

    recorder_native_endpoint_list_destroy(NULL);

    if (!expect(strcmp(recorder_native_version(), "0.7.0") == 0, "version must be exported") ||
        !expect(recorder_native_start(NULL) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "legacy start(NULL) must reject the handle") ||
        !expect(recorder_native_start_with_options(NULL, NULL) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "options start(NULL) must reject the handle") ||
        !expect(recorder_native_start_selected_audio(NULL, NULL) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "selected-audio start(NULL) must reject the handle") ||
        !expect(recorder_native_set_microphone_muted(NULL, 0U) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "mute(NULL) must reject the handle") ||
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
    legacy_stats.struct_size = RECORDER_NATIVE_STATS_V1_SIZE;
    options = valid_options();
    selected = valid_selected_audio_options();
    if (!expect(recorder_native_start(bridge) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "legacy start must require an output path") ||
        !expect(recorder_native_set_microphone_muted(bridge, 2U) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "mute must reject states other than zero and one") ||
        !expect(recorder_native_set_microphone_muted(bridge, 1U) == RECORDER_NATIVE_INVALID_STATE,
                "mute must require an active mixed capture") ||
        !expect(recorder_native_start_with_options(bridge, NULL) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "NULL options must be rejected") ||
        !expect((selected.struct_size = 0U, recorder_native_start_selected_audio(bridge, &selected)) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "selected-audio must reject a wrong options size") ||
        !expect(recorder_native_get_stats(bridge, NULL) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "NULL stats must be rejected") ||
        !expect(recorder_native_get_stats(bridge, &legacy_stats) == RECORDER_NATIVE_OK,
                "v1 stats prefix must remain accepted") ||
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

    selected = valid_selected_audio_options();
    selected.audio_source = (RecorderNativeSelectedAudioSource)99;
    if (!expect(recorder_native_start_selected_audio(bridge, &selected) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "selected-audio must reject an unknown source")) {
        recorder_native_destroy(bridge);
        return 1;
    }
    selected = valid_selected_audio_options();
    selected.aac_bitrate_bps = 0U;
    if (!expect(recorder_native_start_selected_audio(bridge, &selected) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "selected-audio must require an explicit supported AAC bitrate")) {
        recorder_native_destroy(bridge);
        return 1;
    }
    selected = valid_selected_audio_options();
    selected.render_endpoint_id_utf8 = "render-id";
    if (!expect(recorder_native_start_selected_audio(bridge, &selected) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "process-tree loopback must not fall back to a render endpoint") ||
        !expect(recorder_native_get_state(bridge) == RECORDER_NATIVE_STATE_READY,
                "rejected selected-audio options must not start capture")) {
        recorder_native_destroy(bridge);
        return 1;
    }
    selected = valid_selected_audio_options();
    selected.expected_process_creation_time_100ns = 0U;
    if (!expect(recorder_native_start_selected_audio(bridge, &selected) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "process-tree loopback must require the selected process creation time")) {
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
    options.mode = RECORDER_NATIVE_CAPTURE_SELECTED_APP_MIXED;
    if (!expect(recorder_native_start_with_options(bridge, &options) == RECORDER_NATIVE_INVALID_ARGUMENT,
                "selected-audio mode must require the selected-audio entry point")) {
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
