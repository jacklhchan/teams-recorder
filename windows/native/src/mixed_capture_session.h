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
    std::wstring render_endpoint_id;
    std::wstring microphone_endpoint_id;
    std::uint32_t aac_bitrate_bps = 128000;
    // Zero keeps the established all-system render loopback source. A non-zero
    // PID selects the process-loopback virtual endpoint as the primary source.
    std::uint32_t target_process_id = 0;
    // UTC FILETIME identity of the selected root process. Required whenever
    // target_process_id is non-zero so a reused PID cannot become capture.
    std::uint64_t expected_process_creation_time_100ns = 0;
};
class MixedCaptureSession final {
public:
    MixedCaptureSession(); ~MixedCaptureSession();
    MixedCaptureSession(const MixedCaptureSession&) = delete;
    MixedCaptureSession& operator=(const MixedCaptureSession&) = delete;
    RecorderNativeResult Start(MixedCaptureSessionConfig config);
    RecorderNativeResult Stop();
    RecorderNativeResult SetMicrophoneMuted(bool muted);
    RecorderNativeResult health_result() const;
    RecorderNativeStats stats() const;
    std::string last_error() const;
private: class Impl; std::unique_ptr<Impl> impl_;
};
}
