#include "recorder_native_bridge.h"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>

static_assert(std::is_standard_layout<RecorderNativeStartOptions>::value, "start options must remain C ABI safe");
static_assert(std::is_standard_layout<RecorderNativeMixedStartOptions>::value, "mixed start options must remain C ABI safe");
static_assert(std::is_standard_layout<RecorderNativeStats>::value, "stats must remain C ABI safe");
static_assert(sizeof(RecorderNativeStartOptions) == 32U, "x64 start options layout changed");
static_assert(offsetof(RecorderNativeStartOptions, output_path_utf8) == 8U, "output path offset changed");
static_assert(offsetof(RecorderNativeStartOptions, endpoint_id_utf8) == 16U, "endpoint ID offset changed");
static_assert(offsetof(RecorderNativeStartOptions, target_process_id) == 24U, "target PID offset changed");
static_assert(sizeof(RecorderNativeStats) == 192U, "x64 stats layout changed");
static_assert(offsetof(RecorderNativeStats, packets) == 32U, "packet counter offset changed");
static_assert(offsetof(RecorderNativeStats, peak) == 88U, "peak offset changed");
static_assert(offsetof(RecorderNativeStats, render_drift_corrections) == 96U, "timeline stats must be additive");
static_assert(RECORDER_NATIVE_STATS_V1_SIZE == 96U, "v1 stats prefix changed");
static_assert(RECORDER_NATIVE_CAPTURE_SYSTEM_LOOPBACK == 0, "capture mode ABI value changed");
static_assert(RECORDER_NATIVE_CAPTURE_MICROPHONE == 1, "capture mode ABI value changed");
static_assert(RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK == 2, "capture mode ABI value changed");
static_assert(RECORDER_NATIVE_CAPTURE_MIXED == 3, "mixed capture mode ABI value changed");
static_assert(sizeof(RecorderNativeMixedStartOptions) == 40U, "x64 mixed options layout changed");
static_assert(offsetof(RecorderNativeMixedStartOptions, output_path_utf8) == 8U, "mixed output path offset changed");
static_assert(offsetof(RecorderNativeMixedStartOptions, microphone_endpoint_id_utf8) == 24U, "mixed microphone offset changed");
static_assert(RECORDER_NATIVE_STATE_STARTING == 4, "state ABI value changed");
static_assert(RECORDER_NATIVE_STATE_STOPPING == 5, "state ABI value changed");
static_assert(RECORDER_NATIVE_ENDPOINT_FLOW_RENDER == 0U, "render flow ABI value changed");
static_assert(RECORDER_NATIVE_ENDPOINT_FLOW_CAPTURE == 1U, "capture flow ABI value changed");
static_assert(RECORDER_NATIVE_ENDPOINT_DEFAULT_CONSOLE == 1U, "console default ABI value changed");
static_assert(RECORDER_NATIVE_ENDPOINT_DEFAULT_MULTIMEDIA == 2U, "multimedia default ABI value changed");
static_assert(RECORDER_NATIVE_ENDPOINT_DEFAULT_COMMUNICATIONS == 4U, "communications default ABI value changed");

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
    RecorderNativeEndpointList* endpoint_list =
        reinterpret_cast<RecorderNativeEndpointList*>(static_cast<std::uintptr_t>(1));
    uint32_t endpoint_count = 0;
    recorder_native_endpoint_list_destroy(nullptr);

    if (!Expect(std::strcmp(recorder_native_version(), "0.5.0") == 0) ||
        !Expect(recorder_native_start(nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) ||
        !Expect(recorder_native_start_with_options(nullptr, nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) ||
        !Expect(recorder_native_stop(nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) ||
        !Expect(recorder_native_get_stats(nullptr, nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) ||
        !Expect(recorder_native_get_state(nullptr) == RECORDER_NATIVE_STATE_FAULTED) ||
        !Expect(recorder_native_enumerate_endpoints(nullptr, &endpoint_list) == RECORDER_NATIVE_INVALID_ARGUMENT) ||
        !Expect(endpoint_list == nullptr) ||
        !Expect(recorder_native_endpoint_list_get_count(nullptr, &endpoint_count) == RECORDER_NATIVE_INVALID_ARGUMENT) ||
        !Expect(recorder_native_endpoint_list_get(nullptr, 0U, nullptr, nullptr, nullptr, nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) ||
        !Expect(std::strstr(recorder_native_get_last_error(nullptr), "null") != nullptr)) {
        return 1;
    }

    RecorderNativeBridge* bridge = recorder_native_create();
    if (!Expect(bridge != nullptr)) { return 1; }

    RecorderNativeStats stats{};
    stats.struct_size = sizeof(stats);
    RecorderNativeStats legacy_stats{};
    legacy_stats.struct_size = RECORDER_NATIVE_STATS_V1_SIZE;
    RecorderNativeStartOptions options = ValidOptions();
    RecorderNativeMixedStartOptions mixed{};
    mixed.struct_size = sizeof(mixed);
    mixed.output_path_utf8 = "contract-test.m4a";
    mixed.aac_bitrate_bps = 128000U;
    const bool passed =
        Expect(recorder_native_get_state(bridge) == RECORDER_NATIVE_STATE_READY) &&
        Expect(recorder_native_start(bridge) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect(recorder_native_start_with_options(bridge, nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect(recorder_native_start_mixed(nullptr, nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect(recorder_native_set_microphone_muted(nullptr, 0U) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect(recorder_native_set_microphone_muted(bridge, 2U) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect(recorder_native_set_microphone_muted(bridge, 0U) == RECORDER_NATIVE_INVALID_STATE) &&
        Expect(recorder_native_set_microphone_muted(bridge, 1U) == RECORDER_NATIVE_INVALID_STATE) &&
        Expect((mixed.struct_size = 0U, recorder_native_start_mixed(bridge, &mixed)) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect((mixed.struct_size = sizeof(mixed), mixed.output_path_utf8 = "not-m4a.wav", recorder_native_start_mixed(bridge, &mixed)) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect((mixed.output_path_utf8 = "contract-test.m4a", mixed.aac_bitrate_bps = 1000U, recorder_native_start_mixed(bridge, &mixed)) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect(recorder_native_get_stats(bridge, nullptr) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect(recorder_native_get_stats(bridge, &legacy_stats) == RECORDER_NATIVE_OK) &&
        Expect(legacy_stats.struct_size == RECORDER_NATIVE_STATS_V1_SIZE) &&
        Expect(recorder_native_get_stats(bridge, &stats) == RECORDER_NATIVE_OK) &&
        Expect(stats.struct_size == sizeof(stats)) &&
        Expect(stats.event_driven == 0U) &&
        Expect(stats.packets == 0U && stats.input_frames == 0U && stats.output_frames == 0U) &&
        Expect((options.struct_size = 0U, recorder_native_start_with_options(bridge, &options)) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect((options = ValidOptions(), options.output_path_utf8 = nullptr,
                recorder_native_start_with_options(bridge, &options)) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect((options = ValidOptions(), options.mode = static_cast<RecorderNativeCaptureMode>(99),
                recorder_native_start_with_options(bridge, &options)) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect((options = ValidOptions(), options.target_process_id = 42U,
                recorder_native_start_with_options(bridge, &options)) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect((options = ValidOptions(), options.mode = RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK,
                options.target_process_id = 42U, options.endpoint_id_utf8 = "endpoint-id",
                recorder_native_start_with_options(bridge, &options)) == RECORDER_NATIVE_INVALID_ARGUMENT) &&
        Expect(recorder_native_get_state(bridge) == RECORDER_NATIVE_STATE_READY);
    recorder_native_destroy(bridge);
    return passed ? 0 : 1;
}
