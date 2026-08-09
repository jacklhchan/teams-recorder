#pragma once

#include <cstdint>

namespace recorder::video {

// The native WGC session owns the final revalidation against Windows. This
// tiny state machine owns the complementary routing guarantee: a frame is
// usable only if it belongs to the current exact identity and the generation
// that was committed after the most recent target transition.
struct ExactWindowIdentity {
    std::uintptr_t window_handle = 0;
    std::uint32_t process_id = 0;
    std::uint64_t process_creation_time_100ns = 0;

    bool IsUsable() const noexcept {
        return window_handle != 0 && process_id != 0 &&
            process_creation_time_100ns != 0;
    }

    bool operator==(const ExactWindowIdentity& other) const noexcept {
        return window_handle == other.window_handle &&
            process_id == other.process_id &&
            process_creation_time_100ns == other.process_creation_time_100ns;
    }
};

// Used under MixedCaptureSession's mutex. Each Begin* method fences every
// previously queued/callback frame immediately, before WGC teardown or setup
// can take place. Callers must choose a black frame while AllowsFrame is false.
class DynamicVideoRoute final {
public:
    std::uint64_t BeginReplace() noexcept {
        AdvanceGeneration();
        transitioning_ = true;
        active_ = false;
        identity_ = {};
        return generation_;
    }

    bool CommitReplace(std::uint64_t generation,
                       ExactWindowIdentity identity) noexcept {
        if (generation != generation_ || !transitioning_ || !identity.IsUsable()) {
            return false;
        }
        identity_ = identity;
        active_ = true;
        transitioning_ = false;
        return true;
    }

    bool RejectReplace(std::uint64_t generation) noexcept {
        if (generation != generation_ || !transitioning_) return false;
        active_ = false;
        identity_ = {};
        transitioning_ = false;
        return true;
    }

    void Disable() noexcept {
        AdvanceGeneration();
        active_ = false;
        transitioning_ = false;
        identity_ = {};
    }

    bool MarkTargetLost(std::uint64_t generation) noexcept {
        if (generation != generation_ || !active_) return false;
        AdvanceGeneration();
        active_ = false;
        transitioning_ = false;
        identity_ = {};
        return true;
    }

    bool AllowsFrame(std::uint64_t generation,
                     ExactWindowIdentity identity) const noexcept {
        return active_ && !transitioning_ && generation == generation_ &&
            identity == identity_;
    }

    std::uint64_t generation() const noexcept { return generation_; }
    ExactWindowIdentity identity() const noexcept { return identity_; }
    bool requires_privacy_black_frame() const noexcept {
        return transitioning_ || !active_;
    }

    // Video target loss intentionally does not request an audio stop. The
    // mixer remains the authority for audio health and timeline continuity.
    bool audio_may_continue() const noexcept { return true; }

private:
    void AdvanceGeneration() noexcept {
        ++generation_;
        // Reserve zero as the uninitialized/no-callback value.
        if (generation_ == 0) ++generation_;
    }

    std::uint64_t generation_ = 0;
    ExactWindowIdentity identity_{};
    bool active_ = false;
    bool transitioning_ = false;
};

}  // namespace recorder::video
