#pragma once

#include <chrono>
#include <cstdint>
#include <ratio>

namespace recorder::timeline {

// Drives the output timeline even when a valid Windows loopback endpoint is
// silent and therefore emits no WASAPI packets. The mixer may deliberately
// trail live capture by a small latency, but Stop() always exposes the full
// elapsed duration so the final file cannot compress quiet intervals.
class SessionDurationClock final {
public:
    using Clock = std::chrono::steady_clock;

    void Reset() noexcept {
        started_ = false;
        stopped_ = false;
        started_at_ = {};
        stopped_at_ = {};
    }

    void Start(Clock::time_point now = Clock::now()) noexcept {
        started_at_ = now;
        stopped_at_ = {};
        started_ = true;
        stopped_ = false;
    }

    void Stop(Clock::time_point now = Clock::now()) noexcept {
        if (!started_ || stopped_) return;
        stopped_at_ = now < started_at_ ? started_at_ : now;
        stopped_ = true;
    }

    std::uint64_t DueFrames(
        Clock::time_point now = Clock::now(),
        std::uint64_t live_latency_frames = 0) const noexcept {
        if (!started_) return 0;
        const Clock::time_point end = stopped_
            ? stopped_at_
            : (now < started_at_ ? started_at_ : now);
        using FrameDuration = std::chrono::duration<std::uint64_t, std::ratio<1, 48'000>>;
        const auto elapsed_frames =
            std::chrono::duration_cast<FrameDuration>(end - started_at_).count();
        if (stopped_ || elapsed_frames <= live_latency_frames) return stopped_ ? elapsed_frames : 0;
        return elapsed_frames - live_latency_frames;
    }

    bool started() const noexcept { return started_; }
    bool stopped() const noexcept { return stopped_; }

private:
    Clock::time_point started_at_{};
    Clock::time_point stopped_at_{};
    bool started_ = false;
    bool stopped_ = false;
};

}  // namespace recorder::timeline
