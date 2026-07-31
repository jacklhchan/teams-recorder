#include "mixed_capture_session.h"

#include "linear_resampler.h"
#include "m4a_writer.h"
#include "mix_format_decoder.h"
#include "process_loopback.h"
#include "selected_audio_session_facade.h"
#include "wasapi_capture.h"
#include "canonical_timeline.h"

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <chrono>
#include <condition_variable>
#include <cwctype>
#include <deque>
#include <iomanip>
#include <mutex>
#include <sstream>
#include <thread>
#include <utility>
#include <vector>

namespace recorder::bridge {
namespace {

constexpr std::uint32_t kFramesPerBlock = 960;  // 20 ms at 48 kHz.
constexpr std::uint64_t kBlock100ns = 200'000;
constexpr std::size_t kMaxQueuedFrames = 48'000U * 4U;
constexpr auto kSourceSkewWait = std::chrono::milliseconds(60);

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

struct Source {
    std::unique_ptr<recorder::audio::WasapiCapture> capture;
    std::unique_ptr<teams_recorder::process_loopback::ProcessLoopbackCapture> process_capture;
    std::unique_ptr<recorder::format::MixFormat> format;
    std::unique_ptr<recorder::resample::LinearResampler> resampler;
    std::vector<std::uint8_t> format_bytes;
    std::deque<recorder::timeline::AudioChunk> queue;
    std::size_t queued_frames = 0;
    bool received_audio = false;
    bool disconnect_accounted = false;
    float level_peak = 0.0F;
    float level_rms = 0.0F;
    std::uint64_t generation = 0;
    selected_audio::MixedSourceRole role = selected_audio::MixedSourceRole::Primary;
    recorder::timeline::Source timeline_source = recorder::timeline::Source::Render;
};

struct RawAudioBlock {
    std::vector<std::uint8_t> bytes;
    std::vector<std::uint8_t> mix_format_bytes;
    std::uint32_t frame_count = 0;
    std::uint64_t device_position_frames = 0;
    std::uint64_t qpc_position = 0;
    bool silent = false;
    bool discontinuity = false;
    bool event_driven = true;
};

RawAudioBlock ToRaw(recorder::audio::AudioBlock&& block) {
    return {std::move(block.bytes), std::move(block.mix_format_bytes), block.frame_count,
            block.device_position_frames, block.qpc_position, block.silent,
            block.discontinuity, block.event_driven};
}

std::string HresultText(HRESULT value) {
    std::ostringstream text;
    text << "0x" << std::uppercase << std::hex << std::setw(8) << std::setfill('0')
         << static_cast<std::uint32_t>(value);
    return text.str();
}

std::string SupportLogText(std::wstring value) {
    // Friendly endpoint names are OS-provided, not application-controlled,
    // but normalise them before placing them in a single-line support log.
    // The shared-WASAPI initialization context may contain a persistent
    // endpoint ID after this marker, so do not surface that part.
    const auto endpoint_detail = value.find(L" (endpoint=");
    if (endpoint_detail != std::wstring::npos) {
        value.erase(endpoint_detail);
    }
    for (wchar_t& character : value) {
        if (character < L' ' || character == 0x7f) {
            character = L' ';
        }
    }
    while (!value.empty() && std::iswspace(value.front())) {
        value.erase(value.begin());
    }
    while (!value.empty() && std::iswspace(value.back())) {
        value.pop_back();
    }
    constexpr std::size_t kMaxSupportTextCharacters = 160;
    if (value.size() > kMaxSupportTextCharacters) {
        value.resize(kMaxSupportTextCharacters);
        value += L"...";
    }
    return WideToUtf8(value);
}

std::string CaptureSourceType(const selected_audio::MixedSourceRole role) {
    return role == selected_audio::MixedSourceRole::Primary
        ? "systemLoopback"
        : "microphone";
}

RawAudioBlock ToRaw(teams_recorder::process_loopback::ProcessLoopbackAudioBlock&& block) {
    return {std::move(block.bytes), std::move(block.mix_format_bytes), block.frame_count,
            block.device_position_frames, block.qpc_position, block.silent,
            block.discontinuity, block.event_driven};
}

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
            ++session_generation_;
            render_ = {};
            microphone_ = {};
            render_.timeline_source = recorder::timeline::Source::Render;
            microphone_.timeline_source = recorder::timeline::Source::Microphone;
            render_.role = selected_audio::MixedSourceRole::Primary;
            microphone_.role = selected_audio::MixedSourceRole::OptionalMicrophone;
            render_.timeline_source = selected_audio::PrimaryFor(config_.target_process_id) ==
                    selected_audio::PrimarySource::SystemRender
                ? recorder::timeline::Source::Render
                : recorder::timeline::Source::Process;
            timeline_ = {};
            next_output_frame_ = 0;
            stats_ = {};
            stats_.struct_size = sizeof(stats_);
            stats_.mode = config_.mode;
            stats_.output_sample_rate = 48'000;
            stats_.output_channels = 2;
            stats_.event_driven = 1;
            failure_ = RECORDER_NATIVE_OK;
            error_.clear();
            stop_requested_ = false;
            writer_ready_ = false;
            // Mute is a per-session routing choice.  A previous recording
            // must never leave the next session's selected microphone muted.
            microphone_muted_ = false;
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

        const bool primary_started = selected_audio::PrimaryFor(config_.target_process_id) ==
                selected_audio::PrimarySource::SystemRender
            ? StartWasapiSource(render_, recorder::audio::EndpointFlow::Render,
                                config_.render_endpoint_id)
            : StartProcessSource(
                render_,
                config_.target_process_id,
                config_.expected_process_creation_time_100ns);
        if (!primary_started) {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                FailLocked(
                    RECORDER_NATIVE_CAPTURE_ERROR,
                    SourceErrorText(render_));
                stop_requested_ = true;
                cv_.notify_all();
            }
            return Stop();
        }

        if (!config_.microphone_endpoint_id.empty() &&
            !StartWasapiSource(
                microphone_,
                recorder::audio::EndpointFlow::Capture,
                config_.microphone_endpoint_id)) {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                FailLocked(
                    RECORDER_NATIVE_CAPTURE_ERROR,
                    SourceErrorText(microphone_));
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

        StopSource(render_);
        StopSource(microphone_);
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
        RecorderNativeStats result = stats_;
        // The stable ABI names the primary-source diagnostics "render". For
        // selected-process sessions expose the same slots from Process so the
        // caller still receives drift/gap fault evidence without an ABI fork.
        const auto primary_timeline_source = config_.target_process_id == 0
            ? recorder::timeline::Source::Render
            : recorder::timeline::Source::Process;
        const auto& render_counters = timeline_.counters(primary_timeline_source);
        result.render_drift_corrections = render_counters.drift_corrections;
        result.render_late_packets = render_counters.late_packets;
        result.render_late_frames_dropped = render_counters.late_frames_dropped;
        result.render_queue_overflows = render_counters.queue_overflows;
        result.render_source_disconnects = render_counters.source_disconnects;
        result.render_discontinuities = render_counters.discontinuities;
        const auto& microphone_counters = timeline_.counters(recorder::timeline::Source::Microphone);
        result.microphone_drift_corrections = microphone_counters.drift_corrections;
        result.microphone_late_packets = microphone_counters.late_packets;
        result.microphone_late_frames_dropped = microphone_counters.late_frames_dropped;
        result.microphone_queue_overflows = microphone_counters.queue_overflows;
        result.microphone_source_disconnects = microphone_counters.source_disconnects;
        result.microphone_discontinuities = microphone_counters.discontinuities;
        result.primary_level_peak = render_.level_peak;
        result.primary_level_rms = render_.level_rms;
        result.microphone_level_peak = microphone_.level_peak;
        result.microphone_level_rms = microphone_.level_rms;
        return result;
    }

    std::string last_error() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return error_;
    }

private:
    bool StartWasapiSource(
        Source& source,
        recorder::audio::EndpointFlow flow,
        const std::wstring& endpoint_id) {
        source.capture = std::make_unique<recorder::audio::WasapiCapture>();
        recorder::audio::CaptureRequest request;
        request.flow = flow;
        request.endpoint_id = endpoint_id;
        Source* const source_pointer = &source;
        const std::uint64_t generation = session_generation_;
        source.generation = generation;
        return source.capture->Start(
            std::move(request),
            [this, source_pointer, generation](recorder::audio::AudioBlock&& block) {
                ProcessBlock(*source_pointer, generation, ToRaw(std::move(block)));
            });
    }

    bool StartProcessSource(
        Source& source,
        std::uint32_t target_process_id,
        std::uint64_t expected_process_creation_time_100ns) {
        source.process_capture =
            std::make_unique<teams_recorder::process_loopback::ProcessLoopbackCapture>();
        teams_recorder::process_loopback::ProcessLoopbackCaptureRequest request;
        request.target_process_id = target_process_id;
        request.expected_process_creation_time_100ns = expected_process_creation_time_100ns;
        Source* const source_pointer = &source;
        const std::uint64_t generation = session_generation_;
        source.generation = generation;
        return source.process_capture->Start(
            request,
            [this, source_pointer, generation](
                teams_recorder::process_loopback::ProcessLoopbackAudioBlock&& block) {
                ProcessBlock(*source_pointer, generation, ToRaw(std::move(block)));
            });
    }

    std::string SourceErrorText(const Source& source) const {
        if (source.capture) {
            const auto error = source.capture->last_error();
            std::ostringstream diagnostic;
            diagnostic << "source=" << CaptureSourceType(source.role)
                       << "; stage=" << SupportLogText(error.stage)
                       << "; hresult=" << HresultText(error.hresult)
                       << "; deviceInvalidated="
                       << (error.device_invalidated ? "true" : "false");
            if (!error.endpoint_name.empty()) {
                diagnostic << "; endpointName=" << SupportLogText(error.endpoint_name);
            }
            // Endpoint IDs are persistent device identifiers. Keep them in
            // the in-memory capture object for native debugging, but never
            // copy them into an error string that the application may retain
            // or export as a support log.
            return diagnostic.str();
        }
        if (source.process_capture) {
            const auto error = source.process_capture->last_error();
            std::ostringstream diagnostic;
            diagnostic << "source=selectedProcess"
                       << "; stage=" << SupportLogText(error.message)
                       << "; hresult=" << HresultText(error.hresult);
            return diagnostic.str();
        }
        return "source=unknown; stage=creating mixed audio source; hresult=0x80004005";
    }

    void StopSource(Source& source) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            ++source.generation;  // Reject callbacks that outlive this session.
        }
        if (source.capture) {
            source.capture->Stop();
            if (source.capture->last_error().device_invalidated) {
                std::lock_guard<std::mutex> lock(mutex_);
                timeline_.MarkDisconnected(source.timeline_source);
            }
        }
        if (source.process_capture) {
            source.process_capture->Stop();
            if (source.process_capture->last_error().device_invalidated) {
                std::lock_guard<std::mutex> lock(mutex_);
                timeline_.MarkDisconnected(source.timeline_source);
            }
        }
    }

    RecorderNativeResult FailLocked(
        RecorderNativeResult result,
        std::string text) {
        if (failure_ == RECORDER_NATIVE_OK) {
            failure_ = result;
            error_ = std::move(text);
            // Stop accepting ingress immediately.  The mixer is still allowed
            // to drain the bounded queues below before it closes the backup.
            stop_requested_ = true;
            cv_.notify_all();
        }
        return result;
    }

    void ProcessBlock(
        Source& source, std::uint64_t generation, RawAudioBlock block) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!selected_audio::AcceptsCallback(source.generation, generation) ||
                failure_ != RECORDER_NATIVE_OK || stop_requested_) {
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
                source.level_peak = 0.0F;
                source.level_rms = 0.0F;
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
                double sum_of_squares = 0.0;
                source.level_peak = 0.0F;
                for (const float sample : normalized) {
                    const float magnitude = std::abs(sample);
                    source.level_peak = std::max(source.level_peak, magnitude);
                    sum_of_squares += static_cast<double>(sample) * sample;
                }
                source.level_rms = static_cast<float>(std::sqrt(
                    sum_of_squares / static_cast<double>(normalized.size())));
                const std::size_t frame_count = normalized.size() / 2U;
                const auto placement = timeline_.Place(
                    source.timeline_source,
                    block.qpc_position,
                    block.device_position_frames,
                    source.format->sample_rate,
                    frame_count,
                    block.discontinuity);
                if (placement.late_frames_dropped >= frame_count) {
                    // This packet belongs wholly to media already emitted.
                    // Never move it forward: doing so would duplicate audio.
                    normalized.clear();
                }
                if (placement.late_frames_dropped > 0 &&
                    placement.late_frames_dropped < frame_count) {
                    normalized.erase(
                        normalized.begin(),
                        normalized.begin() + static_cast<std::ptrdiff_t>(
                            placement.late_frames_dropped * 2U));
                }
                const std::size_t accepted_frame_count = normalized.size() / 2U;
                while (source.queued_frames + accepted_frame_count > kMaxQueuedFrames &&
                       !source.queue.empty()) {
                    const recorder::timeline::AudioChunk& discarded = source.queue.front();
                    source.queued_frames -=
                        discarded.samples.size() / 2U - discarded.offset_frames;
                    source.queue.pop_front();
                    ++stats_.discontinuities;
                    timeline_.MarkQueueOverflow(source.timeline_source);
                }

                if (accepted_frame_count > kMaxQueuedFrames ||
                    source.queued_frames + accepted_frame_count > kMaxQueuedFrames) {
                    FailLocked(
                        RECORDER_NATIVE_INTERNAL_ERROR,
                        "The mixed audio queue exceeded its bounded capacity.");
                    return;
                }

                if (accepted_frame_count > 0) {
                    source.queued_frames += accepted_frame_count;
                    source.queue.push_back({std::move(normalized), placement.frame, 0});
                    source.received_audio = true;
                    cv_.notify_one();
                }
            } else {
                source.level_peak = 0.0F;
                source.level_rms = 0.0F;
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

    bool HasBlockCoverageLocked(const Source& source) const {
        if (!source.received_audio) {
            return false;
        }
        const std::uint64_t block_end = next_output_frame_ + kFramesPerBlock;
        return timeline_.end_frame(source.timeline_source) >= block_end;
    }

    bool CanEmitBlockLocked() const {
        // Never let the primary callback commit a 20 ms output block when the
        // optional microphone has supplied only its first 10 ms packet.  That
        // made the mixer advance one block ahead and MixFrames then discarded
        // every subsequently-arriving microphone chunk as already emitted.
        if (!HasBlockCoverageLocked(render_)) {
            return !render_.received_audio && HasBlockCoverageLocked(microphone_);
        }
        return config_.microphone_endpoint_id.empty() ||
            HasBlockCoverageLocked(microphone_);
    }

    bool CanEmitAfterSourceSkewLocked() const {
        // An endpoint may become silent and therefore stop delivering packets.
        // After one bounded wait, progress using the source that has covered
        // the block and represent the other source as silence.  This keeps
        // capture live without reintroducing the normal one-block race above.
        if (HasBlockCoverageLocked(render_)) {
            return true;
        }
        return HasBlockCoverageLocked(microphone_);
    }

    std::size_t QueuedFramesLocked() const {
        return render_.queued_frames + microphone_.queued_frames;
    }

    void DetectUnexpectedDisconnectLocked(Source& source) {
        const bool running = source.capture ? source.capture->is_running()
            : source.process_capture && source.process_capture->is_running();
        if ((!source.capture && !source.process_capture) || running || stop_requested_ ||
            source.disconnect_accounted) {
            return;
        }
        source.disconnect_accounted = true;
        timeline_.MarkDisconnected(source.timeline_source);
        // The microphone was explicitly optional at start. It can be removed,
        // disabled, or rejected by a driver after a valid start; preserve the
        // completed Teams/system audio and leave missing microphone frames as
        // silence rather than converting this into a destructive session fault.
        if (!selected_audio::DisconnectFailsSession(source.role)) {
            return;
        }
        FailLocked(
            RECORDER_NATIVE_CAPTURE_ERROR,
            std::string("The primary mixed audio source stopped unexpectedly. ") +
                SourceErrorText(source));
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
                const bool received_required_coverage = cv_.wait_for(lock, kSourceSkewWait, [this] {
                    return stop_requested_ || failure_ != RECORDER_NATIVE_OK ||
                        CanEmitBlockLocked();
                });

                // WASAPI owns the worker thread, so a device invalidation can
                // occur without another packet arriving to wake the mixer.
                // Poll at the same bounded interval used for silence handling.
                DetectUnexpectedDisconnectLocked(render_);
                DetectUnexpectedDisconnectLocked(microphone_);

                bool should_emit = CanEmitBlockLocked();
                if (!should_emit && !received_required_coverage) {
                    should_emit = CanEmitAfterSourceSkewLocked();
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

                recorder::timeline::MixFrames(&render_.queue, &render_.queued_frames,
                                               next_output_frame_, block.data(), kFramesPerBlock);
                recorder::timeline::MixFrames(&microphone_.queue, &microphone_.queued_frames,
                                               next_output_frame_, block.data(), kFramesPerBlock);
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
                // The writer may already have accepted earlier access units;
                // run the recovery close path rather than discarding them.
                wrote_block = true;
                break;
            }

            wrote_block = true;
            output_time_100ns += kBlock100ns;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                stats_.output_frames += kFramesPerBlock;
                next_output_frame_ += kFramesPerBlock;
                for (const float sample : block) {
                    stats_.peak = (std::max)(stats_.peak, std::abs(sample));
                }
            }
        }

        bool failed = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            failed = failure_ != RECORDER_NATIVE_OK;
        }
        if (failed) {
            if (wrote_block &&
                writer->FinalizeForRecovery(&detail) != recorder::m4a::Error::Ok) {
                // Keep the first capture/source fault as the externally
                // reported cause; the writer retains its named .partial
                // artifact for startup inspection if this close also fails.
                std::lock_guard<std::mutex> lock(mutex_);
                if (error_.empty()) {
                    error_ = detail;
                }
            } else if (!wrote_block) {
                // No accumulated media exists, so the normal destructive
                // cleanup is safe and allows owned-folder cleanup upstream.
                writer->Abort();
            }
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
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    FailLocked(RECORDER_NATIVE_IO_ERROR, detail);
                }
                writer->FinalizeForRecovery(&detail);
                return;
            }
            std::lock_guard<std::mutex> lock(mutex_);
            stats_.output_frames += kFramesPerBlock;
        }

        if (writer->Finalize(&detail) != recorder::m4a::Error::Ok) {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                FailLocked(RECORDER_NATIVE_IO_ERROR, detail);
            }
            writer->FinalizeForRecovery(&detail);
        }
    }

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::condition_variable ready_cv_;
    MixedCaptureSessionConfig config_;
    Source render_;
    Source microphone_;
    recorder::timeline::CanonicalTimeline timeline_;
    std::uint64_t session_generation_ = 0;
    std::uint64_t next_output_frame_ = 0;
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
