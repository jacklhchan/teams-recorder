#pragma once

#include "recorder_native_bridge.h"

#include <string_view>

namespace recorder::teams {

inline RecorderNativeTeamsMuteButtonState InterpretMicrophoneButtonAction(
    std::wstring_view action_name) noexcept {
    if (action_name == L"Mute mic") {
        return RECORDER_NATIVE_TEAMS_MUTE_BUTTON_UNMUTED;
    }
    if (action_name == L"Unmute mic") {
        return RECORDER_NATIVE_TEAMS_MUTE_BUTTON_MUTED;
    }
    return RECORDER_NATIVE_TEAMS_MUTE_BUTTON_UNAVAILABLE;
}

}  // namespace recorder::teams
