#include "wgc_window_capture_session.h"

#include <dwmapi.h>
#include <windows.h>

#include <cstdlib>
#include <cmath>
#include <iostream>
#include <string_view>

namespace {

void Expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
        std::exit(1);
    }
}

recorder::video::WgcWindowCaptureConfig ValidShape() {
    recorder::video::WgcWindowCaptureConfig config{};
    config.target.window = reinterpret_cast<HWND>(static_cast<std::uintptr_t>(1));
    config.target.process_id = 1;
    config.target.process_creation_time_100ns = 1;
    config.canvas_width = 1'600;
    config.canvas_height = 900;
    config.max_queued_frames = 3;
    return config;
}

void InvalidConfigurationsFailBeforeAnyCaptureSourceIsCreated() {
    recorder::video::WgcWindowCaptureSession session;
    auto config = ValidShape();
    config.canvas_width = 1'599;
    const auto odd_canvas = session.Start(config);
    Expect(odd_canvas.error == recorder::video::WgcCaptureError::kInvalidArgument,
           "Odd canvas must be refused before WGC capture starts.");
    Expect(session.State() == recorder::video::WgcWindowCaptureState::kIdle,
           "Invalid configuration must not create a session.");

    config = ValidShape();
    config.max_queued_frames = 0;
    const auto zero_queue = session.Start(config);
    Expect(zero_queue.error == recorder::video::WgcCaptureError::kInvalidArgument,
           "An unbounded/zero queue must be refused before WGC capture starts.");

    config = ValidShape();
    config.target.window = nullptr;
    const auto no_target = session.Start(config);
    Expect(no_target.error == recorder::video::WgcCaptureError::kInvalidArgument,
           "A missing target must not fall back to desktop capture.");
}

void DeadOrMismatchedTargetCannotStartCapture() {
    recorder::video::WgcWindowCaptureSession session;
    const auto identity = recorder::video::BuildWgcWindowTargetIdentity(nullptr, nullptr);
    Expect(identity.error == recorder::video::WgcCaptureError::kTargetNotLive,
           "Identity creation must reject a null HWND.");

    auto config = ValidShape();
    const auto result = session.Start(config);
    Expect(result.error == recorder::video::WgcCaptureError::kTargetIdentityMismatch,
           "A dead exact HWND must be rejected rather than rebound or replaced.");
    Expect(!session.IsRunning(), "A rejected HWND must never become a running capture session.");
    session.Stop();
    session.Stop();
}

struct LiveWindowState {
    COLORREF colour = RGB(0, 0, 0);
    std::uint32_t frame_marker = 1;
};

LRESULT CALLBACK LiveWindowProcedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_NCCREATE) {
        const auto create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
        SetWindowLongPtrW(window, GWLP_USERDATA,
                          reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    const auto state = reinterpret_cast<LiveWindowState*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_PAINT && state != nullptr) {
        PAINTSTRUCT paint{};
        HDC dc = BeginPaint(window, &paint);
        RECT client{};
        GetClientRect(window, &client);
        HBRUSH brush = CreateSolidBrush(state->colour);
        FillRect(dc, &client, brush);
        DeleteObject(brush);
        const int marker_extent = 24;
        const COLORREF marker = (state->frame_marker & 1U) == 0U ? RGB(255, 255, 255) : RGB(0, 0, 0);
        HBRUSH marker_brush = CreateSolidBrush(marker);
        RECT corner{client.left, client.top, client.left + marker_extent, client.top + marker_extent};
        FillRect(dc, &corner, marker_brush);
        DeleteObject(marker_brush);
        EndPaint(window, &paint);
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

HWND CreateLiveWindow(LiveWindowState* state = nullptr) {
    constexpr wchar_t class_name[] = L"RecorderWgcWindowCaptureSessionLiveTest";
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = LiveWindowProcedure;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = class_name;
    if (RegisterClassW(&window_class) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return nullptr;
    }
    HWND window = CreateWindowExW(0, class_name, L"Recorder WGC live frame smoke test",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 320, 180, nullptr, nullptr,
        window_class.hInstance, state);
    if (window != nullptr) {
        ShowWindow(window, SW_SHOWNOACTIVATE);
        UpdateWindow(window);
    }
    return window;
}

void PumpMessages() {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
}

bool WaitForFrame(recorder::video::WgcWindowCaptureSession* session,
                  recorder::video::WgcNv12Frame* frame,
                  DWORD timeout_milliseconds) {
    const ULONGLONG deadline = GetTickCount64() + timeout_milliseconds;
    while (GetTickCount64() < deadline) {
        PumpMessages();
        if (session->WaitPopFrame(frame, 25)) return true;
    }
    return false;
}

std::uint8_t CentreLuma(const recorder::video::WgcNv12Frame& frame) {
    Expect(frame.width > 2 && frame.height > 2 && frame.stride >= frame.width,
           "WGC acceptance frame has invalid geometry.");
    return frame.bytes[static_cast<std::size_t>(frame.height / 2U) * frame.stride + frame.width / 2U];
}

void SetLiveWindowColour(HWND window, LiveWindowState* state, COLORREF colour) {
    state->colour = colour;
    ++state->frame_marker;
    InvalidateRect(window, nullptr, FALSE);
    RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ERASE);
    // WGC is compositor-driven. Flush the GDI/DWM transaction before waiting
    // for a new frame so this live-only acceptance test does not mistake a
    // pending composition update for a target-content failure.
    (void)DwmFlush();
}

int LiveExactWindowSmokeTest() {
    HWND window = CreateLiveWindow();
    if (window == nullptr) {
        std::cerr << "Could not create live WGC self-test window.\n";
        return 1;
    }
    recorder::video::WgcWindowTargetIdentity target{};
    const auto identity = recorder::video::BuildWgcWindowTargetIdentity(window, &target);
    if (!identity.succeeded()) {
        std::cerr << "Could not build live WGC self-test identity: "
                  << recorder::video::WgcCaptureErrorName(identity.error) << '\n';
        DestroyWindow(window);
        return 1;
    }
    recorder::video::WgcWindowCaptureSession session;
    recorder::video::WgcWindowCaptureConfig config{};
    config.target = target;
    config.canvas_width = 160;
    config.canvas_height = 90;
    config.max_queued_frames = 2;
    const auto started = session.Start(config);
    if (!started.succeeded()) {
        std::cerr << "Live WGC frame smoke test could not start: "
                  << recorder::video::WgcCaptureErrorName(started.error) << '\n';
        session.Stop();
        DestroyWindow(window);
        // A non-interactive Windows worker can lack a graphics-capture
        // desktop. This manual-only mode reports that condition as a skip.
        return started.error == recorder::video::WgcCaptureError::kPlatformUnavailable ? 0 : 1;
    }
    recorder::video::WgcNv12Frame frame{};
    bool received = false;
    received = WaitForFrame(&session, &frame, 5'000U);
    session.Stop();
    DestroyWindow(window);
    Expect(received, "Live exact-HWND WGC session did not yield a frame.");
    Expect(frame.width == 160 && frame.height == 90 && frame.stride == 160,
           "Live WGC frame did not retain the requested fixed NV12 canvas.");
    Expect(frame.bytes.size() == static_cast<std::size_t>(160U * 90U * 3U / 2U),
           "Live WGC frame did not contain a complete NV12 payload.");
    std::cout << "WGC exact-window live frame smoke test passed.\n";
    return 0;
}

int LiveResizeAndTargetLossAcceptanceTest() {
    LiveWindowState state{};
    HWND window = CreateLiveWindow(&state);
    if (window == nullptr) return 1;
    recorder::video::WgcWindowTargetIdentity target{};
    const auto identity = recorder::video::BuildWgcWindowTargetIdentity(window, &target);
    if (!identity.succeeded()) { DestroyWindow(window); return 1; }
    recorder::video::WgcWindowCaptureSession session;
    recorder::video::WgcWindowCaptureConfig config{};
    config.target = target;
    config.canvas_width = 160;
    config.canvas_height = 90;
    config.max_queued_frames = 2;
    const auto started = session.Start(config);
    if (!started.succeeded()) {
        session.Stop();
        DestroyWindow(window);
        return started.error == recorder::video::WgcCaptureError::kPlatformUnavailable ? 0 : 1;
    }
    recorder::video::WgcNv12Frame first{};
    Expect(WaitForFrame(&session, &first, 5'000U), "Acceptance WGC session did not yield its first frame.");
    const auto first_luma = CentreLuma(first);
    const auto before_resize = session.Stats().frame_pool_recreations;
    SetWindowPos(window, nullptr, 20, 20, 640, 360, SWP_NOZORDER | SWP_NOACTIVATE);
    SetLiveWindowColour(window, &state, RGB(255, 255, 255));
    recorder::video::WgcNv12Frame changed{};
    bool changed_content = false;
    bool received_changed_frame = false;
    const ULONGLONG content_deadline = GetTickCount64() + 5'000U;
    while (GetTickCount64() < content_deadline && !changed_content) {
        if (WaitForFrame(&session, &changed, 250U)) {
            received_changed_frame = true;
            changed_content = std::abs(static_cast<int>(CentreLuma(changed)) - static_cast<int>(first_luma)) >= 80;
        }
    }
    if (!changed_content) {
        std::cerr << "Exact-window capture did not reflect target-only painted content changes (first luma="
                  << static_cast<unsigned>(first_luma);
        if (received_changed_frame) {
            std::cerr << ", last luma=" << static_cast<unsigned>(CentreLuma(changed));
        } else {
            std::cerr << ", no post-paint frame was delivered";
        }
        std::cerr << ").\n";
        session.Stop();
        DestroyWindow(window);
        return 1;
    }
    const auto after_resize = session.Stats().frame_pool_recreations;
    Expect(after_resize > before_resize, "WGC frame pool was not recreated after target resize.");
    Expect(changed.width == 160 && changed.height == 90 && changed.stride == 160,
           "WGC resize changed the immutable NV12 encoder canvas.");
    DestroyWindow(window);
    const ULONGLONG loss_deadline = GetTickCount64() + 2'000U;
    while (GetTickCount64() < loss_deadline && session.State() != recorder::video::WgcWindowCaptureState::kFailed) {
        PumpMessages();
        Sleep(10);
    }
    const auto result = session.LastResult();
    session.Stop();
    Expect(result.error == recorder::video::WgcCaptureError::kTargetLost,
           "Destroyed exact target did not fail closed as target-lost.");
    std::cout << "WGC resize/content/target-loss acceptance test passed.\n";
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc == 2 && std::string_view(argv[1]) == "--live") {
        return LiveExactWindowSmokeTest();
    }
    if (argc == 2 && std::string_view(argv[1]) == "--live-acceptance") {
        return LiveResizeAndTargetLossAcceptanceTest();
    }
    if (argc != 1) {
        std::cerr << "Usage: Recorder.WgcWindowCaptureSession.Tests [--live|--live-acceptance]\n";
        return 64;
    }
    InvalidConfigurationsFailBeforeAnyCaptureSourceIsCreated();
    DeadOrMismatchedTargetCannotStartCapture();
    std::cout << "WGC exact-window session validation tests passed.\n";
    return 0;
}
