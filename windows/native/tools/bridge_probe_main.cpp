#include "recorder_native_bridge.h"

#include <windows.h>

#include <charconv>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <string_view>

namespace {

void PrintUsage() {
    std::cerr
        << "Usage:\n"
        << "  Recorder.BridgeProbe.exe system <seconds> <output.wav> [endpoint-id]\n"
        << "  Recorder.BridgeProbe.exe mic <seconds> <output.wav> [endpoint-id]\n"
        << "  Recorder.BridgeProbe.exe process <pid> <seconds> <output.wav>\n";
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

}  // namespace

int main(int argc, char** argv) {
    if (argc < 4) {
        PrintUsage();
        return 64;
    }

    const std::string mode_text(argv[1]);
    RecorderNativeStartOptions options{};
    options.struct_size = sizeof(options);
    std::uint32_t seconds = 0;

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
    RecorderNativeResult result = recorder_native_start_with_options(bridge, &options);
    if (result != RECORDER_NATIVE_OK) {
        PrintFailure(bridge, "start", result);
        exit_code = 1;
    } else {
        std::cout << "recording mode=" << mode_text << " seconds=" << seconds
                  << " output=" << options.output_path_utf8 << "\n";
        Sleep(seconds * 1000U);
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
    recorder_native_destroy(bridge);
    return exit_code;
}
