#pragma once
#include "recorder_native_bridge.h"
#include <filesystem>
#include <cstdint>
#include <memory>
#include <string>

namespace recorder::bridge {
struct MixedCaptureSessionConfig {
    RecorderNativeCaptureMode mode = RECORDER_NATIVE_CAPTURE_MIXED;
    std::filesystem::path output_path;
    // New safety-fMP4 sessions pass the exact managed-owned
    // recording.audio-safety.partial.mp4 work path. Legacy M4A callers leave
    // this false and retain the established sibling-partial + rename flow.
    bool audio_output_is_work_file = false;
    std::wstring render_endpoint_id;
    std::wstring microphone_endpoint_id;
    std::uint32_t aac_bitrate_bps = 128000;
    // Zero keeps the established all-system render loopback source. A non-zero
    // PID selects the process-loopback virtual endpoint as the primary source.
    std::uint32_t target_process_id = 0;
    // UTC FILETIME identity of the selected root process. Required whenever
    // target_process_id is non-zero so a reused PID cannot become capture.
    std::uint64_t expected_process_creation_time_100ns = 0;
    // When video_output_path is set this remains the independently playable
    // audio-safety artifact while the session muxes a fixed-canvas H.264/AAC
    // MP4.  Until an exact HWND is enabled (and during every target
    // transition), the video track receives privacy-black frames. An empty
    // path preserves the established audio-only behaviour for legacy callers.
    std::filesystem::path video_output_path;
    std::uintptr_t target_window_handle = 0;
    std::uint32_t target_window_process_id = 0;
    std::uint64_t target_window_process_creation_time_100ns = 0;
    std::uint32_t video_width = 0;
    std::uint32_t video_height = 0;
    std::uint32_t video_frame_rate = 30;
    std::uint32_t video_bitrate_bps = 0;
};
class MixedCaptureSession final {
public:
    MixedCaptureSession(); ~MixedCaptureSession();
    MixedCaptureSession(const MixedCaptureSession&) = delete;
    MixedCaptureSession& operator=(const MixedCaptureSession&) = delete;
    RecorderNativeResult Start(MixedCaptureSessionConfig config);
    RecorderNativeResult Stop();
    RecorderNativeResult SetMicrophoneMuted(bool muted);
    RecorderNativeResult SetMicrophonePcmCallback(
        RecorderNativeMicrophonePcmCallback callback,
        void* context);
    RecorderNativeResult SetVideoTarget(
        std::uintptr_t window_handle,
        std::uint32_t process_id,
        std::uint64_t process_creation_time_100ns);
    RecorderNativeResult DisableVideoTarget();
    RecorderNativeResult health_result() const;
    RecorderNativeStats stats() const;
    std::string last_error() const;
private: class Impl; std::unique_ptr<Impl> impl_;
};
}
