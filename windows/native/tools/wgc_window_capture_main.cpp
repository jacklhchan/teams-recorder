#include "wgc_window_capture.h"

#include <atomic>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <thread>

namespace {

bool ParseHandle(const char* text, HWND* window) {
    if (text == nullptr || window == nullptr) {
        return false;
    }
    std::uintptr_t value = 0;
    const char* const end = text + std::char_traits<char>::length(text);
    const auto parsed = std::from_chars(text, end, value);
    if (parsed.ec != std::errc{} || parsed.ptr != end || value == 0) {
        return false;
    }
    *window = reinterpret_cast<HWND>(value);
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "Usage: Recorder.WgcWindowCapture.Tool <top-level-hwnd-in-decimal>\n";
        return 64;
    }
    HWND window = nullptr;
    if (!ParseHandle(argv[1], &window)) {
        std::cerr << "HWND must be a non-zero decimal integer.\n";
        return 64;
    }
    std::atomic<std::uint64_t> callback_frames{0};
    recorder::video::WgcWindowCapture capture;
    const auto started = capture.Start(window, [&callback_frames](recorder::video::OwnedBgraFrame&& frame) {
        if (frame.width > 0 && frame.height > 0 &&
            frame.pixels.size() == static_cast<std::size_t>(frame.stride_bytes) *
                static_cast<std::size_t>(frame.height)) {
            ++callback_frames;
        }
    });
    if (started != recorder::video::WgcWindowCaptureStatus::kOk) {
        std::cerr << "start=" << recorder::video::WgcWindowCaptureStatusName(started)
                  << " error=" << capture.last_error() << '\n';
        return 1;
    }
    std::this_thread::sleep_for(std::chrono::seconds(2));
    const auto stopped = capture.Stop();
    const auto stats = capture.stats();
    std::cout << "stop=" << recorder::video::WgcWindowCaptureStatusName(stopped)
              << " callbacks=" << callback_frames.load()
              << " received=" << stats.received_frames
              << " delivered=" << stats.delivered_frames
              << " dropped=" << stats.dropped_frames
              << " recreates=" << stats.frame_pool_recreates << '\n';
    return stopped == recorder::video::WgcWindowCaptureStatus::kOk &&
            callback_frames.load() > 0U ? 0 : 1;
}
