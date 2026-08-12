#include "process_loopback.h"

#include <objbase.h>

#include <atomic>
#include <iostream>
#include <mutex>
#include <string>
#include <vector>

using teams_recorder::process_loopback::ActivateProcessLoopback;
using teams_recorder::process_loopback::ParseProcessId;
using teams_recorder::process_loopback::ProcessLoopbackCapture;
using teams_recorder::process_loopback::ProcessLoopbackCaptureRequest;

namespace {

void PrintUsage() {
    std::wcerr << L"Usage:\n"
               << L"  process_loopback_probe.exe activate <target-pid> [timeout-ms]\n"
               << L"  process_loopback_probe.exe capture <target-pid> <seconds>\n";
}

struct CaptureStats {
    std::atomic<std::uint64_t> packets{0};
    std::atomic<std::uint64_t> frames{0};
    std::atomic<std::uint64_t> bytes{0};
    std::atomic<std::uint64_t> silent_packets{0};
    std::atomic<std::uint64_t> discontinuities{0};
    std::atomic<bool> event_driven{true};
    std::mutex format_mutex;
    std::vector<std::uint8_t> format;
};

int RunCapture(DWORD pid, DWORD seconds) {
    CaptureStats stats;
    ProcessLoopbackCapture capture;
    ProcessLoopbackCaptureRequest request;
    request.target_process_id = pid;
    const bool started = capture.Start(request, [&stats](auto&& block) {
        stats.packets.fetch_add(1, std::memory_order_relaxed);
        stats.frames.fetch_add(block.frame_count, std::memory_order_relaxed);
        stats.bytes.fetch_add(block.bytes.size(), std::memory_order_relaxed);
        if (block.silent) {
            stats.silent_packets.fetch_add(1, std::memory_order_relaxed);
        }
        if (block.discontinuity) {
            stats.discontinuities.fetch_add(1, std::memory_order_relaxed);
        }
        stats.event_driven.store(block.event_driven, std::memory_order_relaxed);
        std::lock_guard<std::mutex> lock(stats.format_mutex);
        if (stats.format.empty()) {
            stats.format = block.mix_format_bytes;
        }
    });
    if (!started) {
        const auto error = capture.last_error();
        std::wcerr << L"Process loopback capture failed: 0x" << std::hex
                   << static_cast<unsigned long>(error.hresult)
                   << (error.activation_timed_out ? L" (activation timeout)" : L"")
                   << L"\n" << error.message << L"\n";
        return 1;
    }

    Sleep(seconds * 1000U);
    capture.Stop();
    const auto error = capture.last_error();
    std::wcout << L"capture pid=" << pid
               << L" packets=" << stats.packets.load()
               << L" frames=" << stats.frames.load()
               << L" ownedBytes=" << stats.bytes.load()
               << L" silentPackets=" << stats.silent_packets.load()
               << L" discontinuities=" << stats.discontinuities.load()
               << L" mode=" << (stats.event_driven.load() ? L"event" : L"polling")
               << L" formatBytes=" << stats.format.size() << L"\n";
    if (FAILED(error.hresult)) {
        std::wcerr << L"Capture stopped with error: 0x" << std::hex
                   << static_cast<unsigned long>(error.hresult) << L"\n"
                   << error.message << L"\n";
        return 1;
    }
    if (stats.packets.load() == 0) {
        std::wcerr << L"No packets were received. This is not a process-audio isolation pass.\n";
        return 2;
    }
    return 0;
}

bool ParseTimeout(const wchar_t* text, DWORD* timeout) {
    const auto parsed = ParseProcessId(text == nullptr ? L"" : text);
    if (!parsed.succeeded()) {
        return false;
    }
    *timeout = parsed.process_id;
    return true;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 3 || argc > 4) {
        PrintUsage();
        return 64;
    }
    const std::wstring command(argv[1]);
    const auto parsed_pid = ParseProcessId(argv[2]);
    if (!parsed_pid.succeeded()) {
        std::wcerr << L"Invalid target PID. Use a non-zero decimal DWORD.\n";
        return 64;
    }
    if (command == L"capture") {
        DWORD seconds = 0;
        if (argc != 4 || !ParseTimeout(argv[3], &seconds) || seconds > 86'400) {
            std::wcerr << L"Capture needs a duration from 1 to 86400 seconds.\n";
            return 64;
        }
        const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(com_hr)) {
            std::wcerr << L"CoInitializeEx failed: 0x" << std::hex
                       << static_cast<unsigned long>(com_hr) << L"\n";
            return 1;
        }
        const int exit_code = RunCapture(parsed_pid.process_id, seconds);
        CoUninitialize();
        return exit_code;
    }
    if (command != L"activate" || argc > 4) {
        PrintUsage();
        return 64;
    }
    DWORD timeout_ms = 10'000;
    if (argc == 4 && !ParseTimeout(argv[3], &timeout_ms)) {
        std::wcerr << L"Invalid timeout. Use a non-zero decimal DWORD.\n";
        return 64;
    }

    const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(com_hr)) {
        std::wcerr << L"CoInitializeEx failed: 0x" << std::hex
                   << static_cast<unsigned long>(com_hr) << L"\n";
        return 1;
    }
    int exit_code = 0;
    {
        const auto result = ActivateProcessLoopback(parsed_pid.process_id, timeout_ms);
        if (!result.succeeded()) {
            std::wcerr << L"Process loopback activation failed: 0x" << std::hex
                       << static_cast<unsigned long>(result.hr)
                       << (result.timed_out ? L" (timeout; late completion discarded)" : L"")
                       << L"\n";
            exit_code = 1;
        } else {
            std::wcout << L"Process loopback activation succeeded for PID "
                       << std::dec << parsed_pid.process_id
                       << L". This probe does not initialize or capture audio.\n";
        }
    }
    CoUninitialize();
    return exit_code;
}
