#include "wgc_capture_probe.h"

#include <windows.h>
#include <roapi.h>

#include <charconv>
#include <cstdint>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>

namespace {

LRESULT CALLBACK ProbeWindowProcedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    return DefWindowProcW(window, message, wparam, lparam);
}

HWND CreateVisibleSelfTestWindow() {
    constexpr wchar_t class_name[] = L"RecorderWgcCaptureProbeWindow";
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = ProbeWindowProcedure;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = class_name;
    if (RegisterClassW(&window_class) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return nullptr;
    }
    HWND window = CreateWindowExW(
        0, class_name, L"Recorder WGC capability probe", WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 320, 180, nullptr, nullptr,
        window_class.hInstance, nullptr);
    if (window != nullptr) {
        ShowWindow(window, SW_SHOWNOACTIVATE);
        UpdateWindow(window);
    }
    return window;
}

class ScopedRoApartment final {
public:
    explicit ScopedRoApartment(RO_INIT_TYPE type) : result_(RoInitialize(type)) {}
    ~ScopedRoApartment() {
        if (SUCCEEDED(result_)) {
            RoUninitialize();
        }
    }
    HRESULT result() const noexcept { return result_; }

private:
    HRESULT result_;
};

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "Usage: Recorder.WgcCaptureProbe.exe <top-level-hwnd-in-decimal|--self-window|--self-window-sta>\n";
        return 64;
    }
    const std::string_view input(argv[1]);
    HWND window = nullptr;
    const bool self_window = input == "--self-window" || input == "--self-window-sta";
    std::optional<ScopedRoApartment> sta_apartment;
    if (input == "--self-window-sta") {
        sta_apartment.emplace(RO_INIT_SINGLETHREADED);
        if (FAILED(sta_apartment->result())) {
            std::cerr << "Could not initialize STA self-test apartment: 0x" << std::hex
                      << static_cast<unsigned long>(sta_apartment->result()) << "\n";
            return 1;
        }
    }
    if (self_window) {
        window = CreateVisibleSelfTestWindow();
        if (window == nullptr) {
            std::cerr << "Could not create visible self-test window.\n";
            return 1;
        }
    } else {
        std::uintptr_t raw_handle = 0;
        const auto parsed = std::from_chars(input.data(), input.data() + input.size(), raw_handle, 10);
        if (parsed.ec != std::errc{} || parsed.ptr != input.data() + input.size() || raw_handle == 0) {
            std::cerr << "HWND must be a non-zero decimal integer.\n";
            return 64;
        }
        window = reinterpret_cast<HWND>(raw_handle);
    }
    const auto result = recorder::video::ProbeWindowGraphicsCapture(window);
    std::cout << "status=" << recorder::video::WgcProbeStatusName(result.status)
              << " hresult=0x" << std::hex << static_cast<unsigned long>(result.hresult)
              << std::dec << " pid=" << result.process_id
              << " targetIntegrity=" << result.target_integrity_rid
              << " currentIntegrity=" << result.current_integrity_rid
              << " apartment=" << recorder::video::WgcProbeApartmentName(result.apartment)
              << " apartmentInitializedByProbe=" << (result.apartment_initialized_by_probe ? "true" : "false")
              << " diagnostic=" << result.diagnostic << "\n";
    if (self_window) {
        DestroyWindow(window);
    }
    return result.status == recorder::video::WgcProbeStatus::kSupported ? 0 : 1;
}
