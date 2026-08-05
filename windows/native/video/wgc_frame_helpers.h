#pragma once

#include <cstddef>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <utility>

namespace recorder::video {

// Owns the lifetime boundary between WinRT event unregistration and callbacks
// that capture a native owner.  Revoke event tokens first, then close this gate
// and wait before releasing that owner.  A callback that raced revocation either
// completes under its lease or observes the closed gate without touching it.
class CallbackGate final {
public:
    void Open() noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        accepting_ = true;
    }

    [[nodiscard]] bool TryEnter() noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!accepting_) return false;
        ++in_flight_;
        return true;
    }

    void Leave() noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        if (in_flight_ != 0) --in_flight_;
        if (in_flight_ == 0) idle_.notify_all();
    }

    void CloseAndWait() noexcept {
        std::unique_lock<std::mutex> lock(mutex_);
        accepting_ = false;
        idle_.wait(lock, [this] { return in_flight_ == 0; });
    }

private:
    std::mutex mutex_;
    std::condition_variable idle_;
    bool accepting_ = false;
    std::uint64_t in_flight_ = 0;
};

class CallbackGateLease final {
public:
    explicit CallbackGateLease(CallbackGate& gate) noexcept
        : gate_(gate.TryEnter() ? &gate : nullptr) {}
    ~CallbackGateLease() { if (gate_ != nullptr) gate_->Leave(); }
    CallbackGateLease(const CallbackGateLease&) = delete;
    CallbackGateLease& operator=(const CallbackGateLease&) = delete;
    [[nodiscard]] explicit operator bool() const noexcept { return gate_ != nullptr; }

private:
    CallbackGate* gate_ = nullptr;
};

struct BgraFrameSize {
    std::int32_t width = 0;
    std::int32_t height = 0;

    [[nodiscard]] bool IsValid() const noexcept { return width > 0 && height > 0; }
};

[[nodiscard]] inline bool FramePoolNeedsRecreate(
    BgraFrameSize current,
    BgraFrameSize incoming) noexcept {
    return !incoming.IsValid() || current.width != incoming.width ||
        current.height != incoming.height;
}

// A capture callback must never retain unbounded owned pixel buffers when its
// consumer is slower than WGC.  This deliberately drops the newest frame when
// full, preserving the already queued temporal order.
template <typename Frame>
class BoundedFrameQueue final {
public:
    explicit BoundedFrameQueue(std::size_t capacity) noexcept : capacity_(capacity) {}

    [[nodiscard]] bool TryPush(Frame&& frame) {
        if (closed_ || capacity_ == 0 || frames_.size() == capacity_) {
            ++dropped_frames_;
            return false;
        }
        frames_.push_back(std::move(frame));
        return true;
    }

    [[nodiscard]] bool TryPop(Frame* frame) {
        if (frame == nullptr || frames_.empty()) {
            return false;
        }
        *frame = std::move(frames_.front());
        frames_.pop_front();
        return true;
    }

    void Close() noexcept { closed_ = true; }
    [[nodiscard]] bool closed() const noexcept { return closed_; }
    [[nodiscard]] std::size_t size() const noexcept { return frames_.size(); }
    [[nodiscard]] std::uint64_t dropped_frames() const noexcept { return dropped_frames_; }

private:
    std::size_t capacity_ = 0;
    std::deque<Frame> frames_;
    std::uint64_t dropped_frames_ = 0;
    bool closed_ = false;
};

}  // namespace recorder::video
