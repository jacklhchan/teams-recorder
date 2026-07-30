#include "mixed_capture_session.h"

#include "linear_resampler.h"
#include "m4a_writer.h"
#include "mix_format_decoder.h"
#include "wasapi_capture.h"

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace recorder::bridge {
namespace {

constexpr std::uint32_t kFramesPerBlock = 960;  // 20 ms at 48 kHz.
constexpr std::uint64_t kBlock100ns = 200'000;
constexpr std::size_t kMaxQueuedFrames = 48'000U * 4U;

std::string WideToUtf8(const std::wstring& value) {
    if (value.empty()) {
        return {};
    }

    const int required = WideCharToMultiByte(
        CP_UTF8,
        WC_ERR_INVALID_CHARS,
        value.data(),
        static_cast<int>(value.size()),
        nullptr,
        0,
        nullptr,
        nullptr);
    if (required <= 0) {
        return "Windows audio error.";
    }

    std::string result(static_cast<std::size_t>(required), '\0');
    if (WideCharToMultiByte(
            CP_UTF8,
            WC_ERR_INVALID_CHARS,
            value.data(),
            static_cast<int>(value.size()),
            result.data(),
            required,
            nullptr,
            nullptr) <= 0) {
        return "Windows audio error.";
    }
    return result;
}

struct Chunk {
    std::vector<float> samples;
    std::size_t offset_frames = 0;
};

struct Source {
    std::unique_ptr<recorder::audio::WasapiCapture> capture;
    std::unique_ptr<recorder::format::MixFormat> format;
    std::unique_ptr<recorder::resample::LinearResampler> resampler;
    std::vector<std::uint8_t> format_bytes;
    std::deque<Chunk> queue;
    std::size_t queued_frames = 0;
    bool received_audio = false;
};

}  // namespace

class MixedCaptureSession::Impl final {
public:
    ~Impl() {
        if (started_ || mixer_.joinable()) {
            (void)Stop();
        }
    }

    RecorderNativeResult Start(MixedCaptureSessionConfig config) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (started_ || mixer_.joinable()) {
                return FailLocked(
                    RECORDER_NATIVE_INVALID_STATE,
                    "Mixed capture is already started.");
            }

            config_ = std::move(config);
            render_ = {};
            microphone_ = {};
            stats_ = {};
            stats_.struct_size = sizeof(stats_);
            stats_.mode = RECORDER_NATIVE_CAPTURE_MIXED;
            stats_.output_sample_rate = 48'000;
            stats_.output_channels = 2;
            stats_.event_driven = 1;
            failure_ = RECORDER_NATIVE_OK;
            error_.clear();
            stop_requested_ = false;
            writer_ready_ = false;
        }

        mixer_ = std::thread([this] { MixerThread(); });
        {
            std::unique_lock<std::mutex> lock(mutex_);
            ready_cv_.wait(lock, [this] { return writer_ready_; });
            if (failure_ != RECORDER_NATIVE_OK) {
                lock.unlock();
                mixer_.join();
                return failure_;
            }
        }

        if (!StartSource(
                render_,
                recorder::audio::EndpointFlow::Render,
                config_.render_endpoint_id)) {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                FailLocked(
                    RECORDER_NATIVE_CAPTURE_ERROR,
                    WideToUtf8(render_.capture->last_error().message));
                stop_requested_ = true;
                cv_.notify_all();
            }
            return Stop();
        }

        if (!config_.microphone_endpoint_id.empty() &&
            !StartSource(
                microphone_,
                recorder::audio::EndpointFlow::Capture,
                config_.microphone_endpoint_id)) {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                FailLocked(
                    RECORDER_NATIVE_CAPTURE_ERROR,
                    WideToUtf8(microphone_.capture->last_error().message));
                stop_requested_ = true;
                cv_.notify_all();
            }
            return Stop();
        }

        {
            std::lock_guard<std::mutex> lock(mutex_);
            started_ = true;
        }
        return RECORDER_NATIVE_OK;
    }

    RecorderNativeResult Stop() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!started_ && !mixer_.joinable()) {
                return failure_ == RECORDER_NATIVE_OK
                    ? RECORDER_NATIVE_INVALID_STATE
                    : failure_;
            }
            stop_requested_ = true;
            cv_.notify_all();
        }

        if (render_.capture) {
            render_.capture->Stop();
        }
        if (microphone_.capture) {
            microphone_.capture->Stop();
        }
        if (mixer_.joinable()) {
            mixer_.join();
        }

        std::lock_guard<std::mutex> lock(mutex_);
        started_ = false;
        return failure_;
    }

    RecorderNativeResult SetMicrophoneMuted(bool muted) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!started_ || !microphone_.capture) {
            error_ = "Microphone mute is available only during mixed capture with a microphone.";
            return RECORDER_NATIVE_INVALID_STATE;
        }

        microphone_muted_ = muted;
        if (microphone_muted_) {
            // WASAPI continues to deliver microphone packets. Drop any audio
            // already waiting to be mixed, then discard future packets in the
            // callback so the bounded queue cannot grow while muted.
            microphone_.queue.clear();
            microphone_.queued_frames = 0;
        }
        cv_.notify_one();
        return RECORDER_NATIVE_OK;
    }

    RecorderNativeResult health_result() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return failure_;
    }

    RecorderNativeStats stats() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return stats_;
    }

    std::string last_error() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return error_;
    }

private:
    bool StartSource(
        Source& source,
        recorder::audio::EndpointFlow flow,
        const std::wstring& endpoint_id) {
        source.capture = std::make_unique<recorder::audio::WasapiCapture>();
        recorder::audio::CaptureRequest request;
        request.flow = flow;
        request.endpoint_id = endpoint_id;
        Source* const source_pointer = &source;
        return source.capture->Start(
            std::move(request),
            [this, source_pointer](recorder::audio::AudioBlock&& block) {
                ProcessBlock(*source_pointer, std::move(block));
            });
    }

    RecorderNativeResult FailLocked(
        RecorderNativeResult result,
        std::string text) {
        if (failure_ == RECORDER_NATIVE_OK) {
            failure_ = result;
            error_ = std::move(text);
        }
        return result;
    }

    void ProcessBlock(
        Source& source,
        recorder::audio::AudioBlock&& block) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (failure_ != RECORDER_NATIVE_OK || stop_requested_) {
                return;
            }

            const bool discard_muted_microphone =
                &source == &microphone_ && microphone_muted_;
            if (discard_muted_microphone) {
                // Receiving this callback has drained the packet from WASAPI.
                // Do not normalize or enqueue it while the microphone is muted.
                if (stats_.packets == 0) {
                    stats_.first_qpc_100ns = block.qpc_position;
                }
                ++stats_.packets;
                stats_.input_frames += block.frame_count;
                stats_.silent_packets += block.silent ? 1U : 0U;
                stats_.discontinuities += block.discontinuity ? 1U : 0U;
                stats_.last_qpc_100ns = block.qpc_position;
                stats_.event_driven = stats_.event_driven != 0 && block.event_driven
                    ? 1U
                    : 0U;
                return;
            }

            if (!source.format) {
                recorder::format::MixFormat decoded_format;
                recorder::format::DecodeError decode_error;
                if (!recorder::format::DecodeMixFormat(
                        block.mix_format_bytes.data(),
                        block.mix_format_bytes.size(),
                        &decoded_format,
                        &decode_error)) {
                    FailLocked(
                        RECORDER_NATIVE_UNSUPPORTED_FORMAT,
                        "A mixed source returned an unsupported format.");
                    return;
                }

                source.format =
                    std::make_unique<recorder::format::MixFormat>(decoded_format);
                source.format_bytes = block.mix_format_bytes;
                source.resampler =
                    std::make_unique<recorder::resample::LinearResampler>(
                        decoded_format.sample_rate,
                        decoded_format.channels);
                if (stats_.source_sample_rate == 0) {
                    stats_.source_sample_rate = decoded_format.sample_rate;
                    stats_.source_channels = decoded_format.channels;
                }
            } else if (source.format_bytes != block.mix_format_bytes) {
                FailLocked(
                    RECORDER_NATIVE_UNSUPPORTED_FORMAT,
                    "A mixed source changed format during recording.");
                return;
            }

            recorder::format::CapturePacketView packet;
            packet.data = block.bytes.empty() ? nullptr : block.bytes.data();
            packet.byte_count = block.bytes.size();
            packet.frame_count = block.frame_count;
            packet.silent = block.silent;

            std::vector<float> decoded;
            std::vector<float> normalized;
            recorder::format::DecodeError decode_error;
            if (!recorder::format::ConvertPacketToInterleavedFloat(
                    *source.format,
                    packet,
                    &decoded,
                    &decode_error) ||
                source.resampler->Process(
                    decoded.data(),
                    block.frame_count,
                    &normalized) != recorder::resample::Error::Ok) {
                FailLocked(
                    RECORDER_NATIVE_UNSUPPORTED_FORMAT,
                    "Normalizing a mixed source failed.");
                return;
            }

            if (!normalized.empty()) {
                const std::size_t frame_count = normalized.size() / 2U;
                while (source.queued_frames + frame_count > kMaxQueuedFrames &&
                       !source.queue.empty()) {
                    const Chunk& discarded = source.queue.front();
                    source.queued_frames -=
                        discarded.samples.size() / 2U - discarded.offset_frames;
                    source.queue.pop_front();
                    ++stats_.discontinuities;
                }

                if (frame_count > kMaxQueuedFrames ||
                    source.queued_frames + frame_count > kMaxQueuedFrames) {
                    FailLocked(
                        RECORDER_NATIVE_INTERNAL_ERROR,
                        "The mixed audio queue exceeded its bounded capacity.");
                    return;
                }

                source.queued_frames += frame_count;
                source.queue.push_back({std::move(normalized), 0});
                source.received_audio = true;
                cv_.notify_one();
            }

            if (stats_.packets == 0) {
                stats_.first_qpc_100ns = block.qpc_position;
            }
            ++stats_.packets;
            stats_.input_frames += block.frame_count;
            stats_.silent_packets += block.silent ? 1U : 0U;
            stats_.discontinuities += block.discontinuity ? 1U : 0U;
            stats_.last_qpc_100ns = block.qpc_position;
            stats_.event_driven = stats_.event_driven != 0 && block.event_driven
                ? 1U
                : 0U;
        } catch (...) {
            std::lock_guard<std::mutex> lock(mutex_);
            FailLocked(
                RECORDER_NATIVE_INTERNAL_ERROR,
                "Mixed capture callback failed.");
        }
    }

    static void PullFrames(Source& source, float* target) {
        std::size_t remaining = kFramesPerBlock;
        while (remaining > 0 && !source.queue.empty()) {
            Chunk& chunk = source.queue.front();
            const std::size_t available =
                chunk.samples.size() / 2U - chunk.offset_frames;
            const std::size_t count = (std::min)(remaining, available);
            for (std::size_t sample = 0; sample < count * 2U; ++sample) {
                target[sample] +=
                    chunk.samples[chunk.offset_frames * 2U + sample];
            }
            chunk.offset_frames += count;
            source.queued_frames -= count;
            target += count * 2U;
            remaining -= count;
            if (chunk.offset_frames == chunk.samples.size() / 2U) {
                source.queue.pop_front();
            }
        }
    }

    bool CanEmitBlockLocked() const {
        // System loopback is the normal master clock. If it has not emitted a
        // packet yet, permit an active microphone to establish the recording
        // clock instead of stalling an otherwise valid mic-only signal.
        return render_.queued_frames >= kFramesPerBlock ||
            (!render_.received_audio &&
             microphone_.queued_frames >= kFramesPerBlock);
    }

    bool CanUseMicrophoneFallbackLocked() const {
        // If a loopback endpoint goes quiet, Windows may stop delivering
        // packets. A bounded wait below makes the mic the temporary master
        // rather than doubling or freezing its timeline.
        return microphone_.queued_frames >= kFramesPerBlock &&
            render_.queued_frames < kFramesPerBlock;
    }

    std::size_t QueuedFramesLocked() const {
        return render_.queued_frames + microphone_.queued_frames;
    }

    void MixerThread() {
        std::string detail;
        recorder::m4a::Error writer_error;
        auto writer = recorder::m4a::Writer::Create(
            config_.output_path,
            config_.aac_bitrate_bps,
            &writer_error,
            &detail);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!writer) {
                FailLocked(RECORDER_NATIVE_IO_ERROR, detail);
            }
            writer_ready_ = true;
            ready_cv_.notify_all();
        }
        if (!writer) {
            return;
        }

        std::uint64_t output_time_100ns = 0;
        bool wrote_block = false;
        for (;;) {
            std::vector<float> block(kFramesPerBlock * 2U, 0.0F);
            {
                std::unique_lock<std::mutex> lock(mutex_);
                cv_.wait_for(lock, std::chrono::milliseconds(60), [this] {
                    return stop_requested_ || failure_ != RECORDER_NATIVE_OK ||
                        CanEmitBlockLocked();
                });

                bool should_emit = CanEmitBlockLocked();
                if (!should_emit && CanUseMicrophoneFallbackLocked()) {
                    should_emit = true;
                }
                if (!should_emit && (stop_requested_ || failure_ != RECORDER_NATIVE_OK)) {
                    should_emit = QueuedFramesLocked() > 0;
                }
                if (!should_emit) {
                    if (stop_requested_ || failure_ != RECORDER_NATIVE_OK) {
                        break;
                    }
                    continue;
                }

                PullFrames(render_, block.data());
                PullFrames(microphone_, block.data());
            }

            for (float& sample : block) {
                sample = std::tanh(sample);
            }
            if (writer->WriteFrames(
                    block.data(),
                    kFramesPerBlock,
                    output_time_100ns,
                    &detail) != recorder::m4a::Error::Ok) {
                std::lock_guard<std::mutex> lock(mutex_);
                FailLocked(RECORDER_NATIVE_IO_ERROR, detail);
                break;
            }

            wrote_block = true;
            output_time_100ns += kBlock100ns;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                stats_.output_frames += kFramesPerBlock;
                for (const float sample : block) {
                    stats_.peak = (std::max)(stats_.peak, std::abs(sample));
                }
            }
        }

        std::lock_guard<std::mutex> lock(mutex_);
        if (failure_ != RECORDER_NATIVE_OK) {
            writer->Abort();
            return;
        }

        // An AAC sink cannot finalize an empty stream. A short silent frame
        // produces a valid, playable test/session artifact when Windows has
        // not delivered any loopback packet (for example on a silent device).
        if (!wrote_block) {
            const std::vector<float> silence(kFramesPerBlock * 2U, 0.0F);
            if (writer->WriteFrames(
                    silence.data(),
                    kFramesPerBlock,
                    0,
                    &detail) != recorder::m4a::Error::Ok) {
                FailLocked(RECORDER_NATIVE_IO_ERROR, detail);
                writer->Abort();
                return;
            }
            stats_.output_frames += kFramesPerBlock;
        }

        if (writer->Finalize(&detail) != recorder::m4a::Error::Ok) {
            FailLocked(RECORDER_NATIVE_IO_ERROR, detail);
        }
    }

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::condition_variable ready_cv_;
    MixedCaptureSessionConfig config_;
    Source render_;
    Source microphone_;
    std::thread mixer_;
    RecorderNativeStats stats_{};
    RecorderNativeResult failure_ = RECORDER_NATIVE_OK;
    std::string error_;
    bool started_ = false;
    bool stop_requested_ = false;
    bool writer_ready_ = false;
    bool microphone_muted_ = false;
};

MixedCaptureSession::MixedCaptureSession()
    : impl_(std::make_unique<Impl>()) {}

MixedCaptureSession::~MixedCaptureSession() = default;

RecorderNativeResult MixedCaptureSession::Start(MixedCaptureSessionConfig config) {
    return impl_->Start(std::move(config));
}

RecorderNativeResult MixedCaptureSession::Stop() {
    return impl_->Stop();
}

RecorderNativeResult MixedCaptureSession::SetMicrophoneMuted(bool muted) {
    return impl_->SetMicrophoneMuted(muted);
}

RecorderNativeResult MixedCaptureSession::health_result() const {
    return impl_->health_result();
}

RecorderNativeStats MixedCaptureSession::stats() const {
    return impl_->stats();
}

std::string MixedCaptureSession::last_error() const {
    return impl_->last_error();
}

}  // namespace recorder::bridge
