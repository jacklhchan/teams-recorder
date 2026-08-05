#include "recorder_native_bridge.h"

#include <windows.h>

#include <charconv>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>
#include <string_view>

namespace {

void PrintUsage() {
    std::cerr
        << "Usage:\n"
        << "  Recorder.BridgeProbe.exe system <seconds> <output.wav> [endpoint-id]\n"
        << "  Recorder.BridgeProbe.exe mic <seconds> <output.wav> [endpoint-id]\n"
        << "  Recorder.BridgeProbe.exe process <pid> <seconds> <output.wav>\n"
        << "  Recorder.BridgeProbe.exe mixed <seconds> <output.m4a> [render-endpoint-id|-] [microphone-endpoint-id|-]\n"
        << "  Recorder.BridgeProbe.exe mixed-video <hwnd> <seconds> <output.m4a> <output.mp4> [render-endpoint-id|-] [microphone-endpoint-id|-]\n"
        << "  Recorder.BridgeProbe.exe selected <pid> <seconds> <output.m4a> [microphone-endpoint-id|-]\n";
}

bool ParsePositiveU32(std::string_view text, std::uint32_t* value) {
    if (value == nullptr || text.empty()) {
        return false;
    }
    std::uint32_t parsed = 0;
    const char* const first = text.data();
    const char* const last = first + text.size();
    const auto result = std::from_chars(first, last, parsed, 10);
    if (result.ec != std::errc{} || result.ptr != last || parsed == 0) {
        return false;
    }
    *value = parsed;
    return true;
}

bool ParsePositiveU64(std::string_view text, std::uint64_t* value) {
    if (value == nullptr || text.empty()) return false;
    std::uint64_t parsed = 0;
    const char* const first = text.data();
    const char* const last = first + text.size();
    const auto result = std::from_chars(first, last, parsed, 10);
    if (result.ec != std::errc{} || result.ptr != last || parsed == 0) return false;
    *value = parsed;
    return true;
}

bool ReadProcessCreationTime100ns(std::uint32_t process_id, std::uint64_t* value) {
    if (value == nullptr) return false;
    const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
    if (process == nullptr) return false;
    FILETIME creation{};
    FILETIME exit{};
    FILETIME kernel{};
    FILETIME user{};
    const BOOL result = GetProcessTimes(process, &creation, &exit, &kernel, &user);
    CloseHandle(process);
    if (!result) return false;
    ULARGE_INTEGER timestamp{};
    timestamp.LowPart = creation.dwLowDateTime;
    timestamp.HighPart = creation.dwHighDateTime;
    *value = timestamp.QuadPart;
    return *value != 0;
}

const char* ResultName(RecorderNativeResult result) {
    switch (result) {
    case RECORDER_NATIVE_OK: return "OK";
    case RECORDER_NATIVE_INVALID_ARGUMENT: return "INVALID_ARGUMENT";
    case RECORDER_NATIVE_INVALID_STATE: return "INVALID_STATE";
    case RECORDER_NATIVE_NOT_IMPLEMENTED: return "NOT_IMPLEMENTED";
    case RECORDER_NATIVE_INTERNAL_ERROR: return "INTERNAL_ERROR";
    case RECORDER_NATIVE_IO_ERROR: return "IO_ERROR";
    case RECORDER_NATIVE_CAPTURE_ERROR: return "CAPTURE_ERROR";
    case RECORDER_NATIVE_UNSUPPORTED_FORMAT: return "UNSUPPORTED_FORMAT";
    }
    return "UNKNOWN";
}

void PrintFailure(RecorderNativeBridge* bridge, const char* operation,
                  RecorderNativeResult result) {
    std::cerr << operation << " failed: " << ResultName(result)
              << " (" << static_cast<int>(result) << ")";
    const char* const diagnostic = recorder_native_get_last_error(bridge);
    if (diagnostic != nullptr && diagnostic[0] != '\0') {
        std::cerr << ": " << diagnostic;
    }
    std::cerr << "\n";
}

void PrintStats(const RecorderNativeStats& stats) {
    std::cout
        << "stats mode=" << static_cast<int>(stats.mode)
        << " sourceRate=" << stats.source_sample_rate
        << " sourceChannels=" << stats.source_channels
        << " outputRate=" << stats.output_sample_rate
        << " outputChannels=" << stats.output_channels
        << " eventDriven=" << stats.event_driven
        << " packets=" << stats.packets
        << " inputFrames=" << stats.input_frames
        << " outputFrames=" << stats.output_frames
        << " silentPackets=" << stats.silent_packets
        << " discontinuities=" << stats.discontinuities
        << " firstQpc100ns=" << stats.first_qpc_100ns
        << " lastQpc100ns=" << stats.last_qpc_100ns
        << " peak=" << stats.peak
        << "\n";
}

void PrintVideoStats(const RecorderNativeWindowVideoStats& stats, RecorderNativeBridge* bridge) {
    std::cout
        << "video-stats result=" << ResultName(stats.result)
        << " running=" << stats.running
        << " receivedFrames=" << stats.received_frames
        << " deliveredFrames=" << stats.delivered_frames
        << " droppedFrames=" << stats.dropped_frames
        << " framePoolRecreates=" << stats.frame_pool_recreates
        << " firstAcceptedVideoPts100ns=" << stats.first_accepted_video_pts_100ns
        << " lastAcceptedVideoEnd100ns=" << stats.last_accepted_video_end_100ns
        << "\n";
    const char* const diagnostic = recorder_native_get_window_video_last_error(bridge);
    if (diagnostic != nullptr && diagnostic[0] != '\0') {
        std::cout << "video-error=" << diagnostic << "\n";
    }
}

bool IsNonEmptyFile(const char* path, const char* label) {
    std::error_code error;
    const std::uintmax_t size = std::filesystem::file_size(std::filesystem::u8path(path), error);
    if (!error && size > 0) return true;
    std::cerr << label << " is missing or empty: " << path;
    if (error) std::cerr << " (" << error.message() << ")";
    std::cerr << "\n";
    return false;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 4) {
        PrintUsage();
        return 64;
    }

    const std::string mode_text(argv[1]);
    RecorderNativeStartOptions options{};
    options.struct_size = sizeof(options);
    RecorderNativeMixedStartOptions mixed_options{};
    mixed_options.struct_size = sizeof(mixed_options);
    RecorderNativeSelectedAudioStartOptions selected_options{};
    selected_options.struct_size = sizeof(selected_options);
    RecorderNativeWindowVideoStartOptions video_options{};
    video_options.struct_size = sizeof(video_options);
    std::uint32_t seconds = 0;
    bool mixed_video = false;

    if (mode_text == "system" || mode_text == "mic") {
        if (argc != 4 && argc != 5) {
            PrintUsage();
            return 64;
        }
        if (!ParsePositiveU32(argv[2], &seconds) || seconds > 86'400U) {
            std::cerr << "seconds must be a decimal value from 1 to 86400\n";
            return 64;
        }
        options.mode = mode_text == "system"
            ? RECORDER_NATIVE_CAPTURE_SYSTEM_LOOPBACK
            : RECORDER_NATIVE_CAPTURE_MICROPHONE;
        options.output_path_utf8 = argv[3];
        options.endpoint_id_utf8 = argc == 5 ? argv[4] : nullptr;
    } else if (mode_text == "process") {
        if (argc != 5 || !ParsePositiveU32(argv[2], &options.target_process_id) ||
            !ParsePositiveU32(argv[3], &seconds) || seconds > 86'400U) {
            PrintUsage();
            return 64;
        }
        options.mode = RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK;
        options.output_path_utf8 = argv[4];
    } else if (mode_text == "mixed") {
        if (argc < 4 || argc > 6 ||
            !ParsePositiveU32(argv[2], &seconds) || seconds > 86'400U) {
            PrintUsage();
            return 64;
        }
        mixed_options.output_path_utf8 = argv[3];
        mixed_options.aac_bitrate_bps = 128000U;
        mixed_options.render_endpoint_id_utf8 =
            argc >= 5 && std::string_view(argv[4]) != "-" ? argv[4] : nullptr;
        mixed_options.microphone_endpoint_id_utf8 =
            argc >= 6 && std::string_view(argv[5]) != "-" ? argv[5] : nullptr;
    } else if (mode_text == "mixed-video") {
        if (argc < 6 || argc > 8 || !ParsePositiveU64(argv[2], &video_options.target_window_handle) ||
            !ParsePositiveU32(argv[3], &seconds) || seconds > 86'400U) {
            PrintUsage();
            return 64;
        }
        mixed_video = true;
        mixed_options.output_path_utf8 = argv[4];
        mixed_options.aac_bitrate_bps = 128000U;
        mixed_options.render_endpoint_id_utf8 =
            argc >= 7 && std::string_view(argv[6]) != "-" ? argv[6] : nullptr;
        mixed_options.microphone_endpoint_id_utf8 =
            argc >= 8 && std::string_view(argv[7]) != "-" ? argv[7] : nullptr;
        video_options.output_path_utf8 = argv[5];
        video_options.frames_per_second = 30U;
        video_options.video_bitrate_bps = 4'000'000U;
    } else if (mode_text == "selected") {
        if ((argc != 5 && argc != 6) ||
            !ParsePositiveU32(argv[2], &selected_options.target_process_id) ||
            !ParsePositiveU32(argv[3], &seconds) || seconds > 86'400U ||
            !ReadProcessCreationTime100ns(
                selected_options.target_process_id,
                &selected_options.expected_process_creation_time_100ns)) {
            PrintUsage();
            return 64;
        }
        selected_options.audio_source = RECORDER_NATIVE_SELECTED_AUDIO_PROCESS_TREE_LOOPBACK;
        selected_options.output_path_utf8 = argv[4];
        selected_options.microphone_endpoint_id_utf8 =
            argc == 6 && std::string_view(argv[5]) != "-" ? argv[5] : nullptr;
        selected_options.included_process_tree = 1U;
        selected_options.aac_bitrate_bps = 128000U;
    } else {
        PrintUsage();
        return 64;
    }

    RecorderNativeBridge* const bridge = recorder_native_create();
    if (bridge == nullptr) {
        std::cerr << "recorder_native_create failed\n";
        return 1;
    }

    int exit_code = 0;
    RecorderNativeResult result = (mode_text == "mixed" || mixed_video)
        ? recorder_native_start_mixed(bridge, &mixed_options)
        : mode_text == "selected"
            ? recorder_native_start_selected_audio(bridge, &selected_options)
            : recorder_native_start_with_options(bridge, &options);
    if (result != RECORDER_NATIVE_OK) {
        PrintFailure(bridge, "start", result);
        exit_code = 1;
    } else {
        std::cout << "recording mode=" << mode_text << " seconds=" << seconds
                  << " output=" << ((mode_text == "mixed" || mixed_video)
                      ? mixed_options.output_path_utf8
                      : mode_text == "selected"
                          ? selected_options.output_path_utf8
                          : options.output_path_utf8) << "\n";
        if (mixed_video) {
            result = recorder_native_start_window_video(bridge, &video_options);
            if (result != RECORDER_NATIVE_OK) {
                PrintFailure(bridge, "start_window_video", result);
                exit_code = 1;
            } else {
                std::cout << "video output=" << video_options.output_path_utf8
                          << " hwnd=" << video_options.target_window_handle << "\n";
                Sleep(seconds * 1000U);
            }
        } else {
            Sleep(seconds * 1000U);
        }
        // This is intentionally the product stop path. It keeps the companion
        // sink attached while M4A drains, then finalizes MP4 at the same boundary.
        result = recorder_native_stop(bridge);
        if (result != RECORDER_NATIVE_OK) {
            PrintFailure(bridge, "stop", result);
            exit_code = 1;
        }
    }

    RecorderNativeStats stats{};
    stats.struct_size = sizeof(stats);
    result = recorder_native_get_stats(bridge, &stats);
    if (result != RECORDER_NATIVE_OK) {
        PrintFailure(bridge, "get_stats", result);
        exit_code = 1;
    } else {
        PrintStats(stats);
    }
    if (mixed_video) {
        RecorderNativeWindowVideoStats video_stats{};
        video_stats.struct_size = sizeof(video_stats);
        result = recorder_native_get_window_video_stats(bridge, &video_stats);
        if (result != RECORDER_NATIVE_OK) {
            PrintFailure(bridge, "get_window_video_stats", result);
            exit_code = 1;
        } else {
            PrintVideoStats(video_stats, bridge);
            if (video_stats.result != RECORDER_NATIVE_OK) exit_code = 1;
            const bool accepted_video_frames =
                video_stats.last_accepted_video_end_100ns > video_stats.first_accepted_video_pts_100ns;
            if (accepted_video_frames &&
                !IsNonEmptyFile(video_options.output_path_utf8, "MP4 output")) {
                exit_code = 1;
            }
        }
        if (!IsNonEmptyFile(mixed_options.output_path_utf8, "M4A output")) exit_code = 1;
    }
    recorder_native_destroy(bridge);
    return exit_code;
}
