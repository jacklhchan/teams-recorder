#include "teams_mute_button_state.h"

#include <cstdlib>

int main() {
    using recorder::teams::InterpretMicrophoneButtonAction;
    if (InterpretMicrophoneButtonAction(L"Mute mic") !=
            RECORDER_NATIVE_TEAMS_MUTE_BUTTON_UNMUTED ||
        InterpretMicrophoneButtonAction(L"Unmute mic") !=
            RECORDER_NATIVE_TEAMS_MUTE_BUTTON_MUTED ||
        InterpretMicrophoneButtonAction(L"") !=
            RECORDER_NATIVE_TEAMS_MUTE_BUTTON_UNAVAILABLE ||
        InterpretMicrophoneButtonAction(L"Mute microphone") !=
            RECORDER_NATIVE_TEAMS_MUTE_BUTTON_UNAVAILABLE) {
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
