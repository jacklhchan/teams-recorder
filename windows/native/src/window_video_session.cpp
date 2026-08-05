#include "window_video_session.h"

#include "mp4_av_writer.h"
#include "av_sync_timeline.h"
#include "wgc_window_capture.h"
#include "window_video_publication_policy.h"

#include <windows.h>

#include <condition_variable>
#include <deque>
#include <filesystem>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace recorder::bridge {
namespace {
constexpr std::uint64_t kHundredNanosecondsPerSecond = 10'000'000ULL;
constexpr std::size_t kMaxQueuedVideoFrames = 4;
constexpr std::size_t kMaxQueuedAudioBlocks = 50; // One second of 20 ms PCM.

RecorderNativeResult ToNativeResult(recorder::video::WgcWindowCaptureStatus status) noexcept {
    switch (status) {
    case recorder::video::WgcWindowCaptureStatus::kOk: return RECORDER_NATIVE_OK;
    case recorder::video::WgcWindowCaptureStatus::kInvalidArgument:
    case recorder::video::WgcWindowCaptureStatus::kUnsupportedTarget: return RECORDER_NATIVE_INVALID_ARGUMENT;
    case recorder::video::WgcWindowCaptureStatus::kInvalidState: return RECORDER_NATIVE_INVALID_STATE;
    default: return RECORDER_NATIVE_CAPTURE_ERROR;
    }
}
bool IsMp4Path(const std::filesystem::path& path) {
    return _wcsicmp(path.extension().wstring().c_str(), L".mp4") == 0;
}
}

class WindowVideoSession::Impl final {
public:
    ~Impl() { (void)Stop(); }

    RecorderNativeResult Start(WindowVideoSessionConfig config) {
        if (config.target_window_handle == 0 || config.output_path.empty() || !IsMp4Path(config.output_path) ||
            config.frames_per_second == 0 || config.frames_per_second > 60 ||
            config.video_bitrate_bps < 100'000 || config.video_bitrate_bps > 50'000'000) {
            return Fail(RECORDER_NATIVE_INVALID_ARGUMENT, "Window video requires a live HWND, .mp4 path, 1-60 FPS, and valid H.264 bitrate.");
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (capture_ || started_) return FailLocked(RECORDER_NATIVE_INVALID_STATE, "Window video capture is already started.");
            config_ = std::move(config); stats_ = {}; stats_.struct_size = sizeof(stats_); stats_.result = RECORDER_NATIVE_OK;
            error_.clear(); accepted_range_ = {}; bootstrap_audio_tail_applied_ = false;
            last_accepted_bgra_.clear(); last_video_next_pts_100ns_ = 0; last_video_frame_duration_100ns_ = 0;
            capture_ = std::make_unique<recorder::video::WgcWindowCapture>();
        }
        const auto status = capture_->Start(reinterpret_cast<HWND>(static_cast<uintptr_t>(config_.target_window_handle)),
            [this](recorder::video::OwnedBgraFrame&& frame) { EnqueueVideo(std::move(frame)); });
        const auto result = ToNativeResult(status);
        if (result != RECORDER_NATIVE_OK) {
            std::lock_guard<std::mutex> lock(mutex_);
            const auto detail = capture_->last_error();
            capture_.reset();
            return FailLocked(result, detail.empty() ? "Starting WGC window capture failed." : detail);
        }
        { std::lock_guard<std::mutex> lock(mutex_); started_ = true; accepting_audio_ = true; stats_.running = 1; writer_stopping_ = false; av_sync_.Start(config_.session_qpc_origin_100ns); }
        writer_worker_ = std::thread([this] { WriterThread(); });
        return RECORDER_NATIVE_OK;
    }

    // Called by the M4A mixer. It makes one bounded copy and never waits for
    // Media Foundation or WGC, so a broken visual companion cannot starve audio.
    void EnqueueAudio(const float* samples, std::uint32_t frames, std::uint64_t start_100ns) noexcept {
        if (samples == nullptr || frames == 0) return;
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!accepting_audio_ || stats_.result != RECORDER_NATIVE_OK) return;
            if (audio_queue_.size() >= kMaxQueuedAudioBlocks) {
                ++stats_.dropped_frames; // Companion-only backpressure evidence.
                return;
            }
            AudioBlock block;
            block.start_100ns = start_100ns;
            block.samples.assign(samples, samples + static_cast<std::size_t>(frames) * 2U);
            audio_queue_.push_back(std::move(block));
            writer_cv_.notify_one();
        } catch (...) {
            // The optional artifact must not throw into the primary mixer.
        }
    }

    RecorderNativeResult Stop() {
        const RecorderNativeResult ingress = StopIngress();
        const RecorderNativeResult finalized = Finalize();
        return ingress != RECORDER_NATIVE_OK ? ingress : finalized;
    }

    RecorderNativeResult StopIngress() {
        std::unique_ptr<recorder::video::WgcWindowCapture> capture;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!capture_ && !started_ && !writer_worker_.joinable())
                return stats_.result == RECORDER_NATIVE_OK ? RECORDER_NATIVE_INVALID_STATE : stats_.result;
            capture = std::move(capture_);
            started_ = false;
            stats_.running = 0;
        }
        if (capture) {
            const auto result = ToNativeResult(capture->Stop());
            std::lock_guard<std::mutex> lock(mutex_);
            CopyCaptureStatsLocked(capture->stats());
            if (result != RECORDER_NATIVE_OK && stats_.result == RECORDER_NATIVE_OK)
                FailLocked(result, capture->last_error());
        }
        std::lock_guard<std::mutex> lock(mutex_);
        return stats_.result;
    }

    RecorderNativeResult Finalize() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            writer_stopping_ = true;
            accepting_audio_ = false;
            writer_cv_.notify_all();
        }
        if (writer_worker_.joinable()) writer_worker_.join();
        std::lock_guard<std::mutex> lock(mutex_);
        return stats_.result;
    }

    RecorderNativeWindowVideoStats stats() const {
        std::lock_guard<std::mutex> lock(mutex_);
        RecorderNativeWindowVideoStats result = stats_;
        if (capture_) CopyCaptureStats(capture_->stats(), &result);
        return result;
    }
    std::string last_error() const { std::lock_guard<std::mutex> lock(mutex_); return error_; }

private:
    struct AudioBlock { std::vector<float> samples; std::uint64_t start_100ns = 0; };

    void EnqueueVideo(recorder::video::OwnedBgraFrame&& frame) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!started_ || stats_.result != RECORDER_NATIVE_OK) return;
            if (video_queue_.size() >= kMaxQueuedVideoFrames) {
                ++stats_.dropped_frames;
                return;
            }
            video_queue_.push_back(std::move(frame));
            writer_cv_.notify_one();
        } catch (...) {}
    }

    void WriterThread() noexcept {
        try {
        for (;;) {
            recorder::video::OwnedBgraFrame video;
            AudioBlock audio;
            bool has_video = false;
            bool has_audio = false;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                writer_cv_.wait(lock, [this] { return writer_stopping_ || !video_queue_.empty() || !audio_queue_.empty(); });
                if (video_queue_.empty() && audio_queue_.empty() && writer_stopping_) break;
                // A canvas cannot be selected before the first WGC frame. Hold
                // bounded PCM until then, rather than creating an MP4 with a
                // guessed resolution.
                // When the first visual frame arrives after queued audio, the
                // AV gate needs that known audio tail before it can decide the
                // frame is within its maximum lead. Do this before choosing
                // the bootstrap frame; do not dequeue the PCM, because it is
                // still required for the AAC stream once the writer exists.
                if (!writer_ && !video_queue_.empty() && !audio_queue_.empty()) {
                    AdvanceQueuedAudioTailForBootstrapLocked();
                }
                if (!video_queue_.empty() && (!writer_ || audio_queue_.empty() ||
                    VideoStart(video_queue_.front()) <= audio_queue_.front().start_100ns)) {
                    video = std::move(video_queue_.front()); video_queue_.pop_front(); has_video = true;
                } else if (writer_ && !audio_queue_.empty()) { audio = std::move(audio_queue_.front()); audio_queue_.pop_front(); has_audio = true; }
                else if (writer_stopping_) { audio_queue_.clear(); break; }
                else continue;
            }
            if (has_video) WriteVideo(std::move(video));
            if (has_audio) WriteAudio(std::move(audio));
        }
        if (writer_ && !accepted_range_.CanPublish() && IsHealthy()) {
            writer_->Abort();
            writer_.reset();
            SetFailure(RECORDER_NATIVE_CAPTURE_ERROR,
                       "No WGC frame passed the A/V timeline gate; no MP4 companion was published.");
        } else if (writer_) {
            std::string detail;
            if (writer_->Finalize(&detail) != recorder::mp4::Error::Ok) {
                (void)writer_->FinalizeForRecovery(&detail);
                SetFailure(RECORDER_NATIVE_IO_ERROR, detail.empty() ? "Finalizing the window MP4 failed; partial evidence was retained." : detail);
            }
            writer_.reset();
        } else if (IsHealthy()) {
            SetFailure(RECORDER_NATIVE_CAPTURE_ERROR,
                       "WGC did not deliver a frame; no MP4 companion was published.");
        }
        } catch (...) {
            SetFailure(RECORDER_NATIVE_INTERNAL_ERROR,
                       "The optional MP4 companion writer failed unexpectedly.");
        }
    }

    void WriteVideo(recorder::video::OwnedBgraFrame&& frame) noexcept {
        { std::lock_guard<std::mutex> lock(mutex_); if (stats_.result != RECORDER_NATIVE_OK) return; }
        if (frame.width <= 0 || frame.height <= 0 || frame.width % 2 != 0 || frame.height % 2 != 0 || frame.stride_bytes != frame.width * 4) {
            SetFailure(RECORDER_NATIVE_CAPTURE_ERROR, "WGC returned an unsupported frame size."); return;
        }
        const auto duration = kHundredNanosecondsPerSecond / config_.frames_per_second;
        const auto placement = av_sync_.PlaceVideo(
            frame.system_relative_time_100ns < 0 ? 0ULL : static_cast<std::uint64_t>(frame.system_relative_time_100ns), duration);
        if (placement.disposition != recorder::timeline::VideoFrameDisposition::Accepted) {
            std::lock_guard<std::mutex> lock(mutex_);
            ++stats_.dropped_frames;
            return;
        }
        std::string detail;
        if (!writer_) {
            recorder::mp4::Error create_error = recorder::mp4::Error::Ok;
            writer_ = recorder::mp4::AvWriter::Create(config_.output_path,
                {static_cast<std::uint32_t>(frame.width), static_cast<std::uint32_t>(frame.height), config_.frames_per_second, config_.video_bitrate_bps},
                128'000, &create_error, &detail);
            if (!writer_) { SetFailure(RECORDER_NATIVE_IO_ERROR, detail.empty() ? "Creating the window MP4 writer failed." : detail); return; }
            canvas_width_ = frame.width;
            canvas_height_ = frame.height;
            first_qpc_100ns_ = frame.system_relative_time_100ns;
        }
        std::vector<std::uint8_t> canvas;
        const std::uint8_t* pixels = frame.pixels.data();
        std::size_t byte_count = frame.pixels.size();
        if (frame.width != canvas_width_ || frame.height != canvas_height_) {
            canvas = LetterboxBgra(frame, canvas_width_, canvas_height_);
            if (canvas.empty()) { SetFailure(RECORDER_NATIVE_CAPTURE_ERROR, "Scaling a resized WGC frame failed."); return; }
            pixels = canvas.data();
            byte_count = canvas.size();
        }
        if (!last_accepted_bgra_.empty()) {
            const auto action = recorder::video::DecideFreshFrame(
                last_video_next_pts_100ns_, placement.presentation_time_100ns);
            if (action == recorder::video::FreshFrameAction::CacheForNextCadence) {
                // Static extension already owns this timestamp. Replace only
                // the cached image, so the next cadence changes visually
                // without sending a backward MF sample.
                last_accepted_bgra_.assign(pixels, pixels + byte_count);
                last_video_frame_duration_100ns_ = placement.duration_100ns;
                return;
            }
            if (action == recorder::video::FreshFrameAction::HoldLastUntilFresh) {
                ExtendStaticVideoTo(placement.presentation_time_100ns);
                if (!IsHealthy()) return;
            }
        }
        if (writer_->WriteVideoFrame(pixels, byte_count, placement.presentation_time_100ns, placement.duration_100ns, &detail) != recorder::mp4::Error::Ok)
            SetFailure(RECORDER_NATIVE_IO_ERROR, detail.empty() ? "Writing the window MP4 frame failed." : detail);
        else {
            accepted_range_.Add(placement.presentation_time_100ns, placement.duration_100ns);
            last_accepted_bgra_.assign(pixels, pixels + byte_count);
            last_video_next_pts_100ns_ = placement.presentation_time_100ns + placement.duration_100ns;
            last_video_frame_duration_100ns_ = placement.duration_100ns;
            std::lock_guard<std::mutex> lock(mutex_);
            stats_.first_accepted_video_pts_100ns = accepted_range_.first_100ns();
            stats_.last_accepted_video_end_100ns = accepted_range_.last_end_100ns();
        }
        (void)first_qpc_100ns_;
    }
    void WriteAudio(AudioBlock&& block) noexcept {
        if (writer_ && IsHealthy()) {
            std::string detail;
            const auto frames = static_cast<std::uint32_t>(block.samples.size() / 2U);
            av_sync_.AdvanceAudioEnd(config_.session_qpc_origin_100ns + block.start_100ns +
                                     static_cast<std::uint64_t>(frames) * kHundredNanosecondsPerSecond / 48'000U);
            if (writer_->WriteAudioBlock(block.samples.data(), frames, block.start_100ns, &detail) != recorder::mp4::Error::Ok)
                SetFailure(RECORDER_NATIVE_IO_ERROR, detail.empty() ? "Writing MP4 companion audio failed." : detail);
            else
                ExtendStaticVideoTo(block.start_100ns +
                    static_cast<std::uint64_t>(frames) * kHundredNanosecondsPerSecond / 48'000U);
        }
    }
    void ExtendStaticVideoTo(std::uint64_t audio_end_100ns) noexcept {
        if (last_accepted_bgra_.empty() || last_video_frame_duration_100ns_ == 0 ||
            last_video_next_pts_100ns_ >= audio_end_100ns || !writer_) return;
        std::string detail;
        while (last_video_next_pts_100ns_ < audio_end_100ns) {
            const auto duration = (std::min)(last_video_frame_duration_100ns_,
                audio_end_100ns - last_video_next_pts_100ns_);
            if (writer_->WriteVideoFrame(last_accepted_bgra_.data(), last_accepted_bgra_.size(),
                                         last_video_next_pts_100ns_, duration, &detail) != recorder::mp4::Error::Ok) {
                SetFailure(RECORDER_NATIVE_IO_ERROR,
                    detail.empty() ? "Extending a static window video frame failed." : detail);
                return;
            }
            accepted_range_.Add(last_video_next_pts_100ns_, duration);
            last_video_next_pts_100ns_ += duration;
            std::lock_guard<std::mutex> lock(mutex_);
            stats_.last_accepted_video_end_100ns = accepted_range_.last_end_100ns();
        }
    }
    void AdvanceQueuedAudioTailForBootstrapLocked() noexcept {
        if (bootstrap_audio_tail_applied_) return;
        for (const auto& block : audio_queue_) {
            const auto frames = static_cast<std::uint64_t>(block.samples.size() / 2U);
            av_sync_.AdvanceAudioEnd(config_.session_qpc_origin_100ns + block.start_100ns +
                frames * kHundredNanosecondsPerSecond / 48'000U);
        }
        bootstrap_audio_tail_applied_ = true;
    }
    static std::vector<std::uint8_t> LetterboxBgra(const recorder::video::OwnedBgraFrame& source,
                                                    std::int32_t canvas_width, std::int32_t canvas_height) {
        if (canvas_width <= 0 || canvas_height <= 0 || source.width <= 0 || source.height <= 0) return {};
        std::vector<std::uint8_t> output(static_cast<std::size_t>(canvas_width) * canvas_height * 4U, 0U);
        const double scale = (std::min)(static_cast<double>(canvas_width) / source.width,
                                        static_cast<double>(canvas_height) / source.height);
        const auto width = (std::max)(1, static_cast<std::int32_t>(source.width * scale));
        const auto height = (std::max)(1, static_cast<std::int32_t>(source.height * scale));
        const auto left = (canvas_width - width) / 2;
        const auto top = (canvas_height - height) / 2;
        for (std::int32_t y = 0; y < height; ++y) for (std::int32_t x = 0; x < width; ++x) {
            const auto sx = (std::min)(source.width - 1, static_cast<std::int32_t>(x / scale));
            const auto sy = (std::min)(source.height - 1, static_cast<std::int32_t>(y / scale));
            const auto destination = (static_cast<std::size_t>(top + y) * canvas_width + left + x) * 4U;
            const auto origin = (static_cast<std::size_t>(sy) * source.width + sx) * 4U;
            output[destination] = source.pixels[origin]; output[destination + 1] = source.pixels[origin + 1];
            output[destination + 2] = source.pixels[origin + 2]; output[destination + 3] = source.pixels[origin + 3];
        }
        return output;
    }
    static void CopyCaptureStats(const recorder::video::WgcWindowCaptureStats& from, RecorderNativeWindowVideoStats* to) {
        to->received_frames = from.received_frames; to->delivered_frames = from.delivered_frames;
        to->dropped_frames += from.dropped_frames; to->frame_pool_recreates = from.frame_pool_recreates;
    }
    void CopyCaptureStatsLocked(const recorder::video::WgcWindowCaptureStats& from) { CopyCaptureStats(from, &stats_); }
    bool IsHealthy() const { std::lock_guard<std::mutex> lock(mutex_); return stats_.result == RECORDER_NATIVE_OK; }
    void SetFailure(RecorderNativeResult result, std::string detail) { std::lock_guard<std::mutex> lock(mutex_); (void)FailLocked(result, std::move(detail)); }
    std::uint64_t VideoStart(const recorder::video::OwnedBgraFrame& frame) const noexcept {
        return frame.system_relative_time_100ns > static_cast<std::int64_t>(config_.session_qpc_origin_100ns)
            ? static_cast<std::uint64_t>(frame.system_relative_time_100ns) - config_.session_qpc_origin_100ns : 0ULL;
    }
    RecorderNativeResult Fail(RecorderNativeResult result, std::string detail) { std::lock_guard<std::mutex> lock(mutex_); return FailLocked(result, std::move(detail)); }
    RecorderNativeResult FailLocked(RecorderNativeResult result, std::string detail) {
        if (stats_.result == RECORDER_NATIVE_OK) { stats_.result = result; error_ = std::move(detail); }
        return stats_.result;
    }

    mutable std::mutex mutex_;
    std::condition_variable writer_cv_;
    WindowVideoSessionConfig config_;
    std::unique_ptr<recorder::video::WgcWindowCapture> capture_;
    std::unique_ptr<recorder::mp4::AvWriter> writer_;
    std::deque<recorder::video::OwnedBgraFrame> video_queue_;
    std::deque<AudioBlock> audio_queue_;
    std::thread writer_worker_;
    RecorderNativeWindowVideoStats stats_{};
    std::string error_;
    std::uint64_t first_qpc_100ns_ = 0;
    recorder::video::AcceptedVideoRange accepted_range_;
    std::vector<std::uint8_t> last_accepted_bgra_;
    std::uint64_t last_video_next_pts_100ns_ = 0;
    std::uint64_t last_video_frame_duration_100ns_ = 0;
    std::int32_t canvas_width_ = 0;
    std::int32_t canvas_height_ = 0;
    bool started_ = false;
    bool accepting_audio_ = false;
    bool writer_stopping_ = false;
    bool bootstrap_audio_tail_applied_ = false;
    recorder::timeline::AvSyncTimeline av_sync_;
};

WindowVideoSession::WindowVideoSession() : impl_(std::make_unique<Impl>()) {}
WindowVideoSession::~WindowVideoSession() = default;
RecorderNativeResult WindowVideoSession::Start(WindowVideoSessionConfig config) { return impl_->Start(std::move(config)); }
void WindowVideoSession::EnqueueAudio(const float* samples, std::uint32_t frames, std::uint64_t start_100ns) noexcept { impl_->EnqueueAudio(samples, frames, start_100ns); }
RecorderNativeResult WindowVideoSession::Stop() { return impl_->Stop(); }
RecorderNativeResult WindowVideoSession::StopIngress() { return impl_->StopIngress(); }
RecorderNativeResult WindowVideoSession::Finalize() { return impl_->Finalize(); }
RecorderNativeWindowVideoStats WindowVideoSession::stats() const { return impl_->stats(); }
std::string WindowVideoSession::last_error() const { return impl_->last_error(); }
}  // namespace recorder::bridge
