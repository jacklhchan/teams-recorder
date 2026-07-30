#include "selected_audio_session_facade.h"

#include <iostream>

int main() {
    using recorder::bridge::selected_audio::AcceptsCallback;
    using recorder::bridge::selected_audio::PrimaryFor;
    using recorder::bridge::selected_audio::PrimarySource;
    if (PrimaryFor(0) != PrimarySource::SystemRender ||
        PrimaryFor(42) != PrimarySource::ProcessLoopback ||
        !AcceptsCallback(9, 9) || AcceptsCallback(10, 9)) {
        std::cerr << "FAIL selected audio session facade\n";
        return 1;
    }
    std::cout << "PASS selected audio session facade\n";
    return 0;
}
