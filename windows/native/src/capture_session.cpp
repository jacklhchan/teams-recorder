#include "capture_session.h"

#include "linear_resampler.h"
#include "mix_format_decoder.h"
#include "process_loopback.h"
#include "wasapi_capture.h"
#include "wav_writer.h"

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <exception>
#include <limits>
#include <mutex>
#include <utility>
#include <vector>

namespace recorder::bridge {
namespace {

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
        return "Windows audio error (message encoding failed).";
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
        return "Windows audio error (message encoding failed).";
    }
    return result;
}

const char* WavErrorText(recorder::wav::Error error) {
    switch (error) {
    case recorder::wav::Error::Ok: return "ok";
    case recorder::wav::Error::InvalidArgument: return "invalid argument";
    case recorder::wav::Error::AlreadyExists: return "final or partial output already exists";
    case recorder::wav::Error::IoError: return "I/O error";
    case recorder::wav::Error::InvalidState: return "invalid writer state";
    case recorder::wav::Error::Overflow: return "RIFF size overflow";
    }
    return "unknown WAV error";
}

}  // namespace

class CaptureSession::Impl final {
public:
    ~Impl() {
        bool should_finalize = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            should_finalize = started_;
        }
        if (should_finalize) {
            (void)Stop();
            return;
        }
        if (wasapi_capture_) {
            wasapi_capture_->Stop();
        }
        if (process_capture_) {
            process_capture_->Stop();
        }
    }

    RecorderNativeResult Start(CaptureSessionConfig config) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (started_) {
                return SetFailureLocked(
                    RECORDER_NATIVE_INVALID_STATE,
                    "Capture session is already started.");
            }
            config_ = std::move(config);
            stats_ = {};
            stats_.struct_size = sizeof(stats_);
            stats_.mode = config_.mode;
            stats_.output_sample_rate = recorder::resample::LinearResampler::kOutputSampleRate;
            stats_.output_channels = 2;
            stats_.event_driven = 1;
            failure_result_ = RECORDER_NATIVE_OK;
            last_error_.clear();
            stopping_ = false;

            std::error_code filesystem_error;
            if (config_.output_path.empty()) {
                return SetFailureLocked(
                    RECORDER_NATIVE_INVALID_ARGUMENT,
                    "A non-empty output path is required.");
            }
            if (config_.mode != RECORDER_NATIVE_CAPTURE_SYSTEM_LOOPBACK &&
                config_.mode != RECORDER_NATIVE_CAPTURE_MICROPHONE &&
                config_.mode != RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK) {
                return SetFailureLocked(
                    RECORDER_NATIVE_INVALID_ARGUMENT,
                    "The capture mode is invalid.");
            }
            if (config_.mode == RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK &&
                config_.target_process_id == 0) {
                return SetFailureLocked(
                    RECORDER_NATIVE_INVALID_ARGUMENT,
                    "Process-loopback capture requires a non-zero target PID.");
            }
            std::filesystem::path partial = config_.output_path;
            partial += L".partial";
            if (std::filesystem::exists(config_.output_path, filesystem_error) ||
                std::filesystem::exists(partial, filesystem_error) ||
                filesystem_error) {
                return SetFailureLocked(
                    RECORDER_NATIVE_IO_ERROR,
                    filesystem_error
                        ? "Cannot inspect output path: " + filesystem_error.message()
                        : "Final or partial output already exists.");
            }
        }

        bool source_started = false;
        if (config_.mode == RECORDER_NATIVE_CAPTURE_PROCESS_LOOPBACK) {
            process_capture_ =
                std::make_unique<teams_recorder::process_loopback::ProcessLoopbackCapture>();
            teams_recorder::process_loopback::ProcessLoopbackCaptureRequest request;
            request.target_process_id = config_.target_process_id;
            source_started = process_capture_->Start(
                request,
                [this](
                    teams_recorder::process_loopback::ProcessLoopbackAudioBlock&& block) {
                    ProcessBlock(
                        std::move(block.bytes),
                        std::move(block.mix_format_bytes),
                        block.frame_count,
                        block.device_position_frames,
                        block.qpc_position,
                        block.silent,
                        block.discontinuity,
                        block.event_driven);
                });
            if (!source_started) {
                const auto error = process_capture_->last_error();
                std::lock_guard<std::mutex> lock(mutex_);
                return SetFailureLocked(
                    RECORDER_NATIVE_CAPTURE_ERROR,
                    WideToUtf8(error.message));
            }
        } else {
            wasapi_capture_ = std::make_unique<recorder::audio::WasapiCapture>();
            recorder::audio::CaptureRequest request;
            request.flow =
                config_.mode == RECORDER_NATIVE_CAPTURE_MICROPHONE
                    ? recorder::audio::EndpointFlow::Capture
                    : recorder::audio::EndpointFlow::Render;
            request.endpoint_id = config_.endpoint_id;
            source_started = wasapi_capture_->Start(
                std::move(request),
                [this](recorder::audio::AudioBlock&& block) {
                    ProcessBlock(
                        std::move(block.bytes),
                        std::move(block.mix_format_bytes),
                        block.frame_count,
                        block.device_position_frames,
                        block.qpc_position,
                        block.silent,
                        block.discontinuity,
                        block.event_driven);
                });
            if (!source_started) {
                const auto error = wasapi_capture_->last_error();
                std::lock_guard<std::mutex> lock(mutex_);
                return SetFailureLocked(
                    RECORDER_NATIVE_CAPTURE_ERROR,
                    WideToUtf8(error.message));
            }
        }

        std::lock_guard<std::mutex> lock(mutex_);
        started_ = true;
        return RECORDER_NATIVE_OK;
    }

    RecorderNativeResult Stop() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!started_) {
                return SetFailureLocked(
                    RECORDER_NATIVE_INVALID_STATE,
                    "Capture session was not started.");
            }
            stopping_ = true;
        }

        if (wasapi_capture_) {
            wasapi_capture_->Stop();
            const auto error = wasapi_capture_->last_error();
            if (FAILED(error.hresult)) {
                std::lock_guard<std::mutex> lock(mutex_);
                if (failure_result_ == RECORDER_NATIVE_OK) {
                    SetFailureLocked(
                        RECORDER_NATIVE_CAPTURE_ERROR,
                        WideToUtf8(error.message));
                }
            }
        }
        if (process_capture_) {
            process_capture_->Stop();
            const auto error = process_capture_->last_error();
            if (FAILED(error.hresult)) {
                std::lock_guard<std::mutex> lock(mutex_);
                if (failure_result_ == RECORDER_NATIVE_OK) {
                    SetFailureLocked(
                        RECORDER_NATIVE_CAPTURE_ERROR,
                        WideToUtf8(error.message));
                }
            }
        }

        std::lock_guard<std::mutex> lock(mutex_);
        started_ = false;
        stopping_ = false;
        if (failure_result_ != RECORDER_NATIVE_OK) {
            if (writer_) {
                writer_->Abort();
            }
            return failure_result_;
        }
        if (!writer_ || !resampler_) {
            return SetFailureLocked(
                RECORDER_NATIVE_CAPTURE_ERROR,
                "Capture stopped before the source produced an audio packet.");
        }

        normalized_.clear();
        const auto flush_result = resampler_->Flush(&normalized_);
        if (flush_result != recorder::resample::Error::Ok) {
            writer_->Abort();
            return SetFailureLocked(
                RECORDER_NATIVE_INTERNAL_ERROR,
                "48 kHz resampler flush failed.");
        }
        if (!normalized_.empty()) {
            for (const float sample : normalized_) {
                stats_.peak = std::max(stats_.peak, std::abs(sample));
            }
            const auto write_result =
                writer_->WriteFrames(normalized_.data(), normalized_.size() / 2U);
            if (write_result != recorder::wav::Error::Ok) {
                writer_->Abort();
                return SetFailureLocked(
                    RECORDER_NATIVE_IO_ERROR,
                    std::string("Writing final resampled frames failed: ") +
                        WavErrorText(write_result) + ".");
            }
        }
        stats_.output_frames = resampler_->output_frames();
        const auto finalize_result = writer_->Finalize();
        if (finalize_result != recorder::wav::Error::Ok) {
            return SetFailureLocked(
                RECORDER_NATIVE_IO_ERROR,
                std::string("Finalizing WAV failed: ") +
                    WavErrorText(finalize_result) + ".");
        }
        return RECORDER_NATIVE_OK;
    }

    RecorderNativeStats stats() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return stats_;
    }

    RecorderNativeResult health_result() {
        std::lock_guard<std::mutex> lock(mutex_);
        DetectStoppedSourceLocked();
        return failure_result_;
    }

    std::string last_error() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return last_error_;
    }

private:
    void DetectStoppedSourceLocked() {
        if (!started_ || stopping_ || failure_result_ != RECORDER_NATIVE_OK) {
            return;
        }
        if (wasapi_capture_ && !wasapi_capture_->is_running()) {
            const auto error = wasapi_capture_->last_error();
            SetFailureLocked(
                RECORDER_NATIVE_CAPTURE_ERROR,
                FAILED(error.hresult)
                    ? WideToUtf8(error.message)
                    : "WASAPI capture stopped unexpectedly.");
            return;
        }
        if (process_capture_ && !process_capture_->is_running()) {
            const auto error = process_capture_->last_error();
            SetFailureLocked(
                RECORDER_NATIVE_CAPTURE_ERROR,
                FAILED(error.hresult)
                    ? WideToUtf8(error.message)
                    : "Process-loopback capture stopped unexpectedly.");
        }
    }

    void ProcessBlock(
        std::vector<std::uint8_t> bytes,
        std::vector<std::uint8_t> format_bytes,
        std::uint32_t frame_count,
        std::uint64_t device_position,
        std::uint64_t qpc_position,
        bool silent,
        bool discontinuity,
        bool event_driven) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (failure_result_ != RECORDER_NATIVE_OK) {
                return;
            }
            if (!mix_format_) {
                recorder::format::MixFormat decoded_format;
                recorder::format::DecodeError decode_error;
                if (!recorder::format::DecodeMixFormat(
                        format_bytes.data(),
                        format_bytes.size(),
                        &decoded_format,
                        &decode_error)) {
                    SetFailureLocked(
                        RECORDER_NATIVE_UNSUPPORTED_FORMAT,
                        "The capture source returned an unsupported mix format.");
                    return;
                }
                mix_format_ =
                    std::make_unique<recorder::format::MixFormat>(decoded_format);
                format_bytes_ = format_bytes;
                resampler_ = std::make_unique<recorder::resample::LinearResampler>(
                    decoded_format.sample_rate,
                    decoded_format.channels);
                recorder::wav::Error writer_error = recorder::wav::Error::Ok;
                writer_ = recorder::wav::Writer::Create(
                    config_.output_path,
                    recorder::resample::LinearResampler::kOutputSampleRate,
                    2,
                    &writer_error);
                if (!writer_) {
                    SetFailureLocked(
                        RECORDER_NATIVE_IO_ERROR,
                        std::string("Creating WAV writer failed: ") +
                            WavErrorText(writer_error) + ".");
                    return;
                }
                stats_.source_sample_rate = decoded_format.sample_rate;
                stats_.source_channels = decoded_format.channels;
            } else if (format_bytes != format_bytes_) {
                SetFailureLocked(
                    RECORDER_NATIVE_UNSUPPORTED_FORMAT,
                    "The capture source changed format during recording.");
                return;
            }

            recorder::format::CapturePacketView packet;
            packet.data = bytes.empty() ? nullptr : bytes.data();
            packet.byte_count = bytes.size();
            packet.frame_count = frame_count;
            packet.silent = silent;
            recorder::format::DecodeError decode_error;
            decoded_.clear();
            if (!recorder::format::ConvertPacketToInterleavedFloat(
                    *mix_format_,
                    packet,
                    &decoded_,
                    &decode_error)) {
                SetFailureLocked(
                    RECORDER_NATIVE_UNSUPPORTED_FORMAT,
                    "Converting a capture packet to float failed.");
                return;
            }

            normalized_.clear();
            const auto resample_result =
                resampler_->Process(decoded_.data(), frame_count, &normalized_);
            if (resample_result != recorder::resample::Error::Ok) {
                SetFailureLocked(
                    RECORDER_NATIVE_INTERNAL_ERROR,
                    "48 kHz streaming resampling failed.");
                return;
            }
            if (!normalized_.empty()) {
                const auto write_result =
                    writer_->WriteFrames(normalized_.data(), normalized_.size() / 2U);
                if (write_result != recorder::wav::Error::Ok) {
                    SetFailureLocked(
                        RECORDER_NATIVE_IO_ERROR,
                        std::string("Writing resampled frames failed: ") +
                            WavErrorText(write_result) + ".");
                    return;
                }
            }

            if (stats_.packets == 0) {
                stats_.first_qpc_100ns = qpc_position;
            }
            ++stats_.packets;
            stats_.input_frames += frame_count;
            stats_.output_frames = resampler_->output_frames();
            stats_.silent_packets += silent ? 1U : 0U;
            stats_.discontinuities += discontinuity ? 1U : 0U;
            stats_.last_qpc_100ns = qpc_position;
            stats_.event_driven =
                stats_.event_driven != 0 && event_driven ? 1U : 0U;
            for (const float sample : normalized_) {
                stats_.peak = std::max(stats_.peak, std::abs(sample));
            }
            (void)device_position;
        } catch (const std::exception& error) {
            std::lock_guard<std::mutex> lock(mutex_);
            SetFailureLocked(
                RECORDER_NATIVE_INTERNAL_ERROR,
                std::string("Capture callback failed: ") + error.what());
        } catch (...) {
            std::lock_guard<std::mutex> lock(mutex_);
            SetFailureLocked(
                RECORDER_NATIVE_INTERNAL_ERROR,
                "Capture callback failed with an unknown error.");
        }
    }

    RecorderNativeResult SetFailureLocked(
        RecorderNativeResult result,
        std::string message) {
        failure_result_ = result;
        last_error_ = std::move(message);
        return result;
    }

    mutable std::mutex mutex_;
    CaptureSessionConfig config_;
    std::unique_ptr<recorder::audio::WasapiCapture> wasapi_capture_;
    std::unique_ptr<
        teams_recorder::process_loopback::ProcessLoopbackCapture>
        process_capture_;
    std::unique_ptr<recorder::wav::Writer> writer_;
    std::unique_ptr<recorder::format::MixFormat> mix_format_;
    std::unique_ptr<recorder::resample::LinearResampler> resampler_;
    std::vector<std::uint8_t> format_bytes_;
    std::vector<float> decoded_;
    std::vector<float> normalized_;
    RecorderNativeStats stats_{};
    RecorderNativeResult failure_result_ = RECORDER_NATIVE_OK;
    std::string last_error_;
    bool started_ = false;
    bool stopping_ = false;
};

CaptureSession::CaptureSession() : impl_(std::make_unique<Impl>()) {}
CaptureSession::~CaptureSession() = default;

RecorderNativeResult CaptureSession::Start(CaptureSessionConfig config) {
    return impl_->Start(std::move(config));
}

RecorderNativeResult CaptureSession::Stop() {
    return impl_->Stop();
}

RecorderNativeResult CaptureSession::health_result() const {
    return impl_->health_result();
}

RecorderNativeStats CaptureSession::stats() const {
    return impl_->stats();
}

std::string CaptureSession::last_error() const {
    return impl_->last_error();
}

}  // namespace recorder::bridge
