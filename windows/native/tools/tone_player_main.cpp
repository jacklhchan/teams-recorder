#include <windows.h>
#include <mmsystem.h>

#include <cstdint>
#include <iostream>
#include <string_view>

namespace {

bool ParseSeconds(std::wstring_view text, DWORD* seconds) {
    if (seconds == nullptr || text.empty()) {
        return false;
    }
    std::uint64_t value = 0;
    for (const wchar_t character : text) {
        if (character < L'0' || character > L'9') {
            return false;
        }
        const std::uint64_t digit = static_cast<std::uint64_t>(character - L'0');
        if (value > (86'400U - digit) / 10U) {
            return false;
        }
        value = value * 10U + digit;
    }
    if (value == 0) {
        return false;
    }
    *seconds = static_cast<DWORD>(value);
    return true;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc != 3) {
        std::wcerr << L"Usage: Recorder.TonePlayer.exe <input.wav> <seconds>\n";
        return 64;
    }
    DWORD seconds = 0;
    if (!ParseSeconds(argv[2], &seconds)) {
        std::wcerr << L"seconds must be a decimal value from 1 to 86400\n";
        return 64;
    }

    if (!PlaySoundW(argv[1], nullptr, SND_FILENAME | SND_ASYNC | SND_LOOP | SND_NODEFAULT)) {
        std::wcerr << L"PlaySoundW failed: " << GetLastError() << L"\n";
        return 1;
    }
    Sleep(seconds * 1000U);
    PlaySoundW(nullptr, nullptr, 0);
    return 0;
}
