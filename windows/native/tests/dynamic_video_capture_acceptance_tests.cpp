#include "dynamic_video_route.h"
#include "trusted_video_frame_hold.h"

#include <cstdlib>
#include <iostream>

namespace {

using recorder::video::DynamicVideoRoute;
using recorder::video::ExactWindowIdentity;
using recorder::video::TrustedVideoFrameHold;

void Expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
        std::exit(1);
    }
}

ExactWindowIdentity Target(std::uintptr_t hwnd, std::uint32_t pid,
                           std::uint64_t created) {
    return {hwnd, pid, created};
}

void MidRecordingAddRemoveReplaceUsesOnlyCurrentFrames() {
    DynamicVideoRoute route;
    const auto first = Target(0x100, 42, 1000);
    const auto first_generation = route.BeginReplace();
    Expect(route.requires_privacy_black_frame(),
           "Adding a target must black-frame before WGC is committed.");
    Expect(route.CommitReplace(first_generation, first),
           "A valid initial target must commit.");
    Expect(route.AllowsFrame(first_generation, first),
           "The committed target must be allowed.");

    const auto second = Target(0x200, 43, 2000);
    const auto second_generation = route.BeginReplace();
    Expect(!route.AllowsFrame(first_generation, first),
           "Replacing a target must reject queued frames from the old window.");
    Expect(route.requires_privacy_black_frame(),
           "Replacing a target must use black frames until the new commit.");
    Expect(route.CommitReplace(second_generation, second),
           "The replacement target must commit.");
    Expect(route.AllowsFrame(second_generation, second),
           "Only the replacement target may provide frames.");

    route.Disable();
    Expect(route.requires_privacy_black_frame(),
           "Disabling target capture must return to black frames.");
    Expect(!route.AllowsFrame(second_generation, second),
           "Disabled capture must reject the old target immediately.");
}

void HwndReuseAndStaleCallbacksFailClosed() {
    DynamicVideoRoute route;
    const auto original = Target(0x1234, 77, 10);
    const auto old_generation = route.BeginReplace();
    Expect(route.CommitReplace(old_generation, original), "Original target must commit.");

    // Same HWND/PID but a new process instance is never the old target.
    const auto recycled = Target(0x1234, 77, 11);
    const auto replacement_generation = route.BeginReplace();
    Expect(!route.AllowsFrame(old_generation, original),
           "A late callback from the prior generation must be rejected.");
    Expect(route.CommitReplace(replacement_generation, recycled),
           "The revalidated replacement may commit.");
    Expect(!route.AllowsFrame(replacement_generation, original),
           "PID/HWND reuse with a different creation time must be rejected.");
    Expect(route.AllowsFrame(replacement_generation, recycled),
           "Only the exact new process instance may provide frames.");
}

void ResizeAndTargetCloseRemainPrivateAndAudioContinues() {
    DynamicVideoRoute route;
    const auto target = Target(0x9876, 88, 123);
    const auto generation = route.BeginReplace();
    Expect(route.CommitReplace(generation, target), "Target must commit for resize test.");

    // WGC letterboxes every source resize into the immutable encoder canvas.
    // The routing gate does not admit an old queued frame during a resize
    // transition; capture code clears the queue and the scheduler emits black.
    const auto resize_generation = route.BeginReplace();
    Expect(route.requires_privacy_black_frame(),
           "Resize/reconfigure period must not reuse a prior window frame.");
    Expect(route.CommitReplace(resize_generation, target),
           "Same exact target may resume after fixed-canvas resize handling.");
    Expect(route.MarkTargetLost(resize_generation),
           "Closing the active target must be observed for its generation.");
    Expect(route.requires_privacy_black_frame(),
           "A closed target must immediately become black video, not a freeze frame.");
    Expect(route.audio_may_continue(),
           "Target loss must not interrupt the independent audio timeline.");
}

void SparseFramesRepeatWithoutPrivacyBlackBlinking() {
    DynamicVideoRoute route;
    TrustedVideoFrameHold hold;
    const auto target = Target(0x4567, 91, 456);
    const auto generation = route.BeginReplace();
    Expect(route.CommitReplace(generation, target),
           "Sparse-frame target must commit.");

    constexpr std::uintptr_t capture_token = 0xABC;
    constexpr std::uint64_t frame_pool_epoch = 7;
    hold.Remember(capture_token, generation, target, frame_pool_epoch);

    Expect(hold.CanRepeat(capture_token, generation, target, frame_pool_epoch,
                          route.AllowsFrame(generation, target), true),
           "A static exact-window frame must be repeated when WGC has no new frame.");
    Expect(hold.CanRepeat(capture_token, generation, target, frame_pool_epoch,
                          route.AllowsFrame(generation, target), true),
           "Repeated empty WGC polls must remain on the trusted frame, not blink black.");
}

void HeldFrameFailsClosedAcrossEveryPrivacyBoundary() {
    DynamicVideoRoute route;
    TrustedVideoFrameHold hold;
    const auto target = Target(0x5678, 92, 567);
    const auto generation = route.BeginReplace();
    Expect(route.CommitReplace(generation, target),
           "Privacy-boundary target must commit.");

    constexpr std::uintptr_t capture_token = 0xDEF;
    constexpr std::uint64_t frame_pool_epoch = 11;
    hold.Remember(capture_token, generation, target, frame_pool_epoch);

    Expect(!hold.CanRepeat(capture_token, generation, target,
                           frame_pool_epoch + 1,
                           route.AllowsFrame(generation, target), true),
           "A frame-pool recreation must invalidate the held pre-resize frame.");
    Expect(!hold.CanRepeat(capture_token + 1, generation, target,
                           frame_pool_epoch,
                           route.AllowsFrame(generation, target), true),
           "A replacement WGC session must not reuse the old session frame.");
    Expect(!hold.CanRepeat(capture_token, generation, target,
                           frame_pool_epoch,
                           route.AllowsFrame(generation, target), false),
           "A stopped capture must not freeze its final frame.");

    route.Disable();
    Expect(!hold.CanRepeat(capture_token, generation, target,
                           frame_pool_epoch,
                           route.AllowsFrame(generation, target), true),
           "Disabling capture must immediately select privacy black.");
}

}  // namespace

int main() {
    MidRecordingAddRemoveReplaceUsesOnlyCurrentFrames();
    HwndReuseAndStaleCallbacksFailClosed();
    ResizeAndTargetCloseRemainPrivateAndAudioContinues();
    SparseFramesRepeatWithoutPrivacyBlackBlinking();
    HeldFrameFailsClosedAcrossEveryPrivacyBoundary();
    return 0;
}
