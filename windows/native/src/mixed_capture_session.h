#pragma once
#include "recorder_native_bridge.h"
#include <filesystem>
#include <memory>
#include <string>

namespace recorder::bridge {
struct MixedCaptureSessionConfig {
    std::filesystem::path output_path;
    std::wstring render_endpoint_id;
    std::wstring microphone_endpoint_id;
    std::uint32_t aac_bitrate_bps = 128000;
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
