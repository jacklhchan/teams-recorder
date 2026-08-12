#pragma once

#include "recorder_native_bridge.h"

#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>

namespace recorder::bridge {

struct CaptureSessionConfig {
    RecorderNativeCaptureMode mode = RECORDER_NATIVE_CAPTURE_SYSTEM_LOOPBACK;
    std::filesystem::path output_path;
    std::wstring endpoint_id;
    std::uint32_t target_process_id = 0;
};

class CaptureSession final {
public:
    CaptureSession();
    ~CaptureSession();
    CaptureSession(const CaptureSession&) = delete;
    CaptureSession& operator=(const CaptureSession&) = delete;

    RecorderNativeResult Start(CaptureSessionConfig config);
    RecorderNativeResult Stop();
    RecorderNativeResult health_result() const;
    RecorderNativeStats stats() const;
    std::string last_error() const;

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace recorder::bridge
