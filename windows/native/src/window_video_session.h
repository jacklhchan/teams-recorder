#pragma once

#include "recorder_native_bridge.h"

#include <filesystem>
#include <memory>
#include <string>

namespace recorder::bridge {

struct WindowVideoSessionConfig final {
    std::uint64_t target_window_handle = 0;
    std::filesystem::path output_path;
    std::uint32_t frames_per_second = 30;
    std::uint32_t video_bitrate_bps = 4'000'000;
    // Same QPC-derived 100 ns origin used by the active M4A timeline.
    std::uint64_t session_qpc_origin_100ns = 0;
};

// This is deliberately not part of MixedCaptureSession. The window MP4 is an
// optional companion artifact; the M4A audio session must stay live if WGC or
// H.264 has an environmental failure.
class WindowVideoSession final {
public:
    WindowVideoSession();
    ~WindowVideoSession();
    WindowVideoSession(const WindowVideoSession&) = delete;
    WindowVideoSession& operator=(const WindowVideoSession&) = delete;

    RecorderNativeResult Start(WindowVideoSessionConfig config);
    void EnqueueAudio(const float* samples, std::uint32_t frames,
                      std::uint64_t start_100ns) noexcept;
    RecorderNativeResult Stop();
    // Two-stage stop used by the primary recorder: first freeze WGC/audio
    // ingress at one boundary, then finalize after the M4A mixer has drained.
    RecorderNativeResult StopIngress();
    RecorderNativeResult Finalize();
    RecorderNativeWindowVideoStats stats() const;
    std::string last_error() const;

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace recorder::bridge
