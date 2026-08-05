#include "wgc_frame_helpers.h"

#include <atomic>
#include <cstdlib>
#include <iostream>
#include <thread>

namespace {

void Expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void SizeChangesRecreateButStableSizesDoNot() {
    using recorder::video::BgraFrameSize;
    using recorder::video::FramePoolNeedsRecreate;
    const BgraFrameSize hd{1280, 720};
    Expect(!FramePoolNeedsRecreate(hd, hd), "stable size recreated the frame pool");
    Expect(FramePoolNeedsRecreate(hd, {1920, 1080}), "resized content did not recreate the frame pool");
    Expect(FramePoolNeedsRecreate(hd, {0, 720}), "invalid content size was accepted");
}

void QueueIsBoundedOrderedAndClosed() {
    recorder::video::BoundedFrameQueue<int> queue(2U);
    Expect(queue.TryPush(1), "first frame was rejected");
    Expect(queue.TryPush(2), "second frame was rejected");
    Expect(!queue.TryPush(3), "full queue accepted an unbounded frame");
    Expect(queue.dropped_frames() == 1U && queue.size() == 2U,
           "full queue accounting changed");
    int value = 0;
    Expect(queue.TryPop(&value) && value == 1, "frame order changed at bounded queue");
    Expect(queue.TryPop(&value) && value == 2, "second frame order changed at bounded queue");
    queue.Close();
    Expect(queue.closed(), "queue did not close");
    Expect(!queue.TryPush(4), "closed queue delivered a frame after stop");
    Expect(queue.dropped_frames() == 2U, "closed queue drop accounting changed");
}

void CallbackGateWaitsForRacingCallbackAndRejectsLateCallbacks() {
    recorder::video::CallbackGate gate;
    gate.Open();
    Expect(gate.TryEnter(), "open callback gate rejected an in-flight callback");

    std::atomic<bool> close_started = false;
    std::atomic<bool> close_returned = false;
    std::thread closer([&] {
        close_started.store(true, std::memory_order_release);
        gate.CloseAndWait();
        close_returned.store(true, std::memory_order_release);
    });
    while (!close_started.load(std::memory_order_acquire)) std::this_thread::yield();
    Expect(!close_returned.load(std::memory_order_acquire),
           "callback gate returned before its racing callback left");
    gate.Leave();
    closer.join();
    Expect(close_returned.load(std::memory_order_acquire),
           "callback gate did not return after the final callback left");
    Expect(!gate.TryEnter(), "closed callback gate accepted a late callback");
}

}  // namespace

int main() {
    SizeChangesRecreateButStableSizesDoNot();
    QueueIsBoundedOrderedAndClosed();
    CallbackGateWaitsForRacingCallbackAndRejectsLateCallbacks();
    std::cout << "PASS WGC frame helpers\n";
    return EXIT_SUCCESS;
}
