#pragma once

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include <sdkddkver.h>

#ifndef NTDDI_VERSION
#define NTDDI_VERSION NTDDI_WIN10_FE
#endif

#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <windows.h>

#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace teams_recorder::process_loopback {

// Process loopback is documented for Windows 10 build 20348 and later.
constexpr DWORD kMinimumSupportedBuild = 20348;

// Move-only RAII ownership for the IAudioClient returned by activation.
class AudioClientHandle {
public:
    AudioClientHandle() = default;
    explicit AudioClientHandle(IAudioClient* value) noexcept : value_(value) {}
    ~AudioClientHandle();

    AudioClientHandle(const AudioClientHandle&) = delete;
    AudioClientHandle& operator=(const AudioClientHandle&) = delete;
    AudioClientHandle(AudioClientHandle&& other) noexcept;
    AudioClientHandle& operator=(AudioClientHandle&& other) noexcept;

    [[nodiscard]] IAudioClient* get() const noexcept { return value_; }
    [[nodiscard]] explicit operator bool() const noexcept { return value_ != nullptr; }
    IAudioClient* release() noexcept;
    void reset(IAudioClient* replacement = nullptr) noexcept;

private:
    IAudioClient* value_ = nullptr;
};

struct ProcessIdParseResult {
    HRESULT hr = E_INVALIDARG;
    DWORD process_id = 0;

    [[nodiscard]] bool succeeded() const noexcept { return SUCCEEDED(hr); }
};

// Accepts only ASCII decimal, non-zero DWORD process IDs. No signs, spaces,
// separators, or trailing characters are accepted.
ProcessIdParseResult ParseProcessId(std::wstring_view text) noexcept;

// Verifies that a process currently exists. Access denied is returned unchanged:
// callers must not reinterpret it as a valid capture target.
HRESULT ValidateTargetProcess(DWORD process_id) noexcept;

// Returns ERROR_OLD_WIN_VERSION when process-loopback activation is unavailable.
HRESULT CheckProcessLoopbackOSSupport() noexcept;

enum class ActivationCompletionDisposition {
    deliver_result,
    release_client,
};

// Kept public so the late-completion contract is independently testable.
ActivationCompletionDisposition ActivationCompletionDispositionFor(
    bool activation_abandoned) noexcept;

struct ProcessLoopbackActivationResult {
    HRESULT hr = E_FAIL;
    bool timed_out = false;
    AudioClientHandle audio_client;

    [[nodiscard]] bool succeeded() const noexcept {
        return SUCCEEDED(hr) && static_cast<bool>(audio_client);
    }
};

// Activates VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK in INCLUDE_TARGET_PROCESS_TREE
// mode. timeout_ms bounds the caller wait only: the OS activation cannot be
// cancelled. If timeout expires, late completion releases its IAudioClient and
// cannot write into caller-owned memory.
ProcessLoopbackActivationResult ActivateProcessLoopback(
    DWORD target_process_id,
    DWORD timeout_ms = 10'000) noexcept;

struct ProcessLoopbackCaptureError {
    HRESULT hresult = S_OK;
    bool device_invalidated = false;
    bool activation_timed_out = false;
    std::wstring message;
};

struct ProcessLoopbackAudioBlock {
    // Owned bytes. For a silent WASAPI packet this remains empty because the
    // native API may provide a null data pointer; callers must honor silent.
    std::vector<std::uint8_t> bytes;
    // Exact WAVEFORMATEX + cbSize bytes from IAudioClient::GetMixFormat().
    std::vector<std::uint8_t> mix_format_bytes;
    std::uint32_t frame_count = 0;
    std::uint64_t device_position_frames = 0;
    std::uint64_t qpc_position = 0;
    bool silent = false;
    bool discontinuity = false;
    // False only when the process virtual endpoint rejected event callbacks
    // and this same target PID was reactivated for bounded polling.
    bool event_driven = true;
};

using ProcessLoopbackAudioBlockCallback =
    std::function<void(ProcessLoopbackAudioBlock&&)>;

struct ProcessLoopbackCaptureRequest {
    DWORD target_process_id = 0;
    DWORD activation_timeout_ms = 10'000;
    // Used only after event-callback initialization fails for this same
    // process-loopback virtual endpoint. Must be non-zero.
    DWORD polling_interval_ms = 10;
};

// A single-target, shared-mode process loopback session. Start/Stop are safe
// from a control thread; callbacks run on the dedicated MTA capture thread and
// must not call Stop synchronously. This class never activates a physical
// endpoint or all-system loopback path.
class ProcessLoopbackCapture final {
public:
    ProcessLoopbackCapture();
    ~ProcessLoopbackCapture();
    ProcessLoopbackCapture(const ProcessLoopbackCapture&) = delete;
    ProcessLoopbackCapture& operator=(const ProcessLoopbackCapture&) = delete;

    bool Start(ProcessLoopbackCaptureRequest request,
               ProcessLoopbackAudioBlockCallback callback);
    void Stop();
    [[nodiscard]] bool is_running() const;
    [[nodiscard]] ProcessLoopbackCaptureError last_error() const;

private:
    void CaptureThread(ProcessLoopbackCaptureRequest request,
                       ProcessLoopbackAudioBlockCallback callback,
                       HANDLE started_event);
    void SetError(HRESULT hresult, const wchar_t* context,
                  bool activation_timed_out = false);

    mutable std::mutex mutex_;
    std::thread worker_;
    HANDLE stop_event_ = nullptr;
    bool running_ = false;
    ProcessLoopbackCaptureError last_error_;
};

}  // namespace teams_recorder::process_loopback
