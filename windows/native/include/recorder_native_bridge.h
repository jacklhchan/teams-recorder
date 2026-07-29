#pragma once

/*
 * Stable C ABI for the Teams Recorder native media bridge.
 * This header is C and C++ compatible; do not expose C++ types across it.
 */

#include <stdint.h>

#if defined(_WIN32)
  #if defined(RECORDER_NATIVE_BRIDGE_BUILDING)
    #define RECORDER_NATIVE_API __declspec(dllexport)
  #else
    #define RECORDER_NATIVE_API __declspec(dllimport)
  #endif
#else
  #define RECORDER_NATIVE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RecorderNativeBridge RecorderNativeBridge;
typedef struct RecorderNativeEndpointList RecorderNativeEndpointList;

typedef enum RecorderNativeResult {
    RECORDER_NATIVE_OK = 0,
    RECORDER_NATIVE_INVALID_ARGUMENT = 1,
    RECORDER_NATIVE_INVALID_STATE = 2,
    RECORDER_NATIVE_NOT_IMPLEMENTED = 3,
    RECORDER_NATIVE_INTERNAL_ERROR = 4,
    RECORDER_NATIVE_IO_ERROR = 5,
    RECORDER_NATIVE_CAPTURE_ERROR = 6,
    RECORDER_NATIVE_UNSUPPORTED_FORMAT = 7
} RecorderNativeResult;

typedef enum RecorderNativeState {
    RECORDER_NATIVE_STATE_READY = 0,
    RECORDER_NATIVE_STATE_RECORDING = 1,
    RECORDER_NATIVE_STATE_STOPPED = 2,
    RECORDER_NATIVE_STATE_FAULTED = 3,
    RECORDER_NATIVE_STATE_STARTING = 4,
    RECORDER_NATIVE_STATE_STOPPING = 5
} RecorderNativeState;

typedef enum RecorderNativeCaptureMode {
    RECORDER_NATIVE_CAPTURE_SYSTEM_LOOPBACK = 0,
    RECORDER_NATIVE_CAPTURE_MICROPHONE = 1,
    RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK = 2,
    /* System render loopback, optionally mixed with one exact capture endpoint. */
    RECORDER_NATIVE_CAPTURE_MIXED = 3
} RecorderNativeCaptureMode;

/*
 * Endpoint flow and default-role values deliberately use fixed-width macros
 * rather than a public enum/bitfield struct. This keeps the endpoint-list ABI
 * additive without imposing packing or lifetime rules on callers.
 */
#define RECORDER_NATIVE_ENDPOINT_FLOW_RENDER 0u
#define RECORDER_NATIVE_ENDPOINT_FLOW_CAPTURE 1u

#define RECORDER_NATIVE_ENDPOINT_DEFAULT_CONSOLE (1u << 0)
#define RECORDER_NATIVE_ENDPOINT_DEFAULT_MULTIMEDIA (1u << 1)
#define RECORDER_NATIVE_ENDPOINT_DEFAULT_COMMUNICATIONS (1u << 2)

typedef struct RecorderNativeStartOptions {
    /* Set to sizeof(RecorderNativeStartOptions) for ABI versioning. */
    uint32_t struct_size;
    RecorderNativeCaptureMode mode;
    /* Required UTF-8 final WAV path. The bridge copies it during this call. */
    const char* output_path_utf8;
    /* Optional UTF-8 WASAPI endpoint ID. NULL/empty selects the default. */
    const char* endpoint_id_utf8;
    /* Required only for RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK. */
    uint32_t target_process_id;
    uint32_t reserved;
} RecorderNativeStartOptions;

/* Additive M4A mixed-capture ABI.  All strings are UTF-8 and copied on start. */
typedef struct RecorderNativeMixedStartOptions {
    uint32_t struct_size;
    /* Required final .m4a path.  The encoder writes <path>.partial first. */
    const char* output_path_utf8;
    /* NULL/empty selects the default render endpoint for system loopback. */
    const char* render_endpoint_id_utf8;
    /* NULL/empty disables microphone capture; a non-empty ID is selected exactly. */
    const char* microphone_endpoint_id_utf8;
    /* AAC target bitrate in bits/sec (64,000 through 320,000). */
    uint32_t aac_bitrate_bps;
    uint32_t reserved;
} RecorderNativeMixedStartOptions;

typedef struct RecorderNativeStats {
    /* Set to sizeof(RecorderNativeStats) before calling get_stats. */
    uint32_t struct_size;
    RecorderNativeCaptureMode mode;
    uint32_t source_sample_rate;
    uint32_t source_channels;
    uint32_t output_sample_rate;
    uint32_t output_channels;
    uint32_t event_driven;
    uint32_t reserved;
    uint64_t packets;
    uint64_t input_frames;
    uint64_t output_frames;
    uint64_t silent_packets;
    uint64_t discontinuities;
    uint64_t first_qpc_100ns;
    uint64_t last_qpc_100ns;
    float peak;
} RecorderNativeStats;

RECORDER_NATIVE_API RecorderNativeBridge* recorder_native_create(void);
RECORDER_NATIVE_API void recorder_native_destroy(RecorderNativeBridge* bridge);

/*
 * Legacy entry point retained for ABI compatibility. It returns
 * RECORDER_NATIVE_INVALID_ARGUMENT because an output path is required.
 */
RECORDER_NATIVE_API RecorderNativeResult recorder_native_start(RecorderNativeBridge* bridge);

/*
 * Starts one capture source and returns after it is running. All pointer fields
 * are copied before return. No source silently falls back to another mode.
 */
RECORDER_NATIVE_API RecorderNativeResult recorder_native_start_with_options(
    RecorderNativeBridge* bridge,
    const RecorderNativeStartOptions* options);

RECORDER_NATIVE_API RecorderNativeResult recorder_native_start_mixed(
    RecorderNativeBridge* bridge,
    const RecorderNativeMixedStartOptions* options);

/* Stops capture, drains the source, flushes 48 kHz stereo output, and finalizes once. */
RECORDER_NATIVE_API RecorderNativeResult recorder_native_stop(RecorderNativeBridge* bridge);
RECORDER_NATIVE_API RecorderNativeState recorder_native_get_state(const RecorderNativeBridge* bridge);
RECORDER_NATIVE_API RecorderNativeResult recorder_native_get_stats(
    const RecorderNativeBridge* bridge,
    RecorderNativeStats* stats);

/*
 * Produces an immutable snapshot of active WASAPI render and capture endpoints.
 * The snapshot owns all returned UTF-8 strings and is independent of the
 * bridge after this call. On failure, *out_list is NULL and the bridge's
 * last-error diagnostic is updated. Do not call this concurrently with another
 * operation on the same bridge when the diagnostic matters.
 */
RECORDER_NATIVE_API RecorderNativeResult recorder_native_enumerate_endpoints(
    RecorderNativeBridge* bridge,
    RecorderNativeEndpointList** out_list);

/* Releases an endpoint snapshot. NULL is accepted. */
RECORDER_NATIVE_API void recorder_native_endpoint_list_destroy(
    RecorderNativeEndpointList* list);

/* Returns the number of snapshot entries. */
RECORDER_NATIVE_API RecorderNativeResult recorder_native_endpoint_list_get_count(
    const RecorderNativeEndpointList* list,
    uint32_t* out_count);

/*
 * Reads one snapshot entry. On success the returned strings are non-NULL,
 * NUL-terminated, immutable, and valid only until list_destroy(list). Callers
 * must copy them before releasing the list and must never free them directly.
 */
RECORDER_NATIVE_API RecorderNativeResult recorder_native_endpoint_list_get(
    const RecorderNativeEndpointList* list,
    uint32_t index,
    uint32_t* out_flow,
    uint32_t* out_default_flags,
    const char** out_endpoint_id_utf8,
    const char** out_friendly_name_utf8);

/*
 * For a non-NULL handle, the pointer is bridge-owned and remains valid until the
 * next API call on that handle or its destruction. The NULL-handle diagnostic is
 * implementation-owned and must not be freed by the caller.
 */
RECORDER_NATIVE_API const char* recorder_native_get_last_error(const RecorderNativeBridge* bridge);

/* Version of this ABI implementation, not the host application's version. */
RECORDER_NATIVE_API const char* recorder_native_version(void);

#ifdef __cplusplus
}
#endif
