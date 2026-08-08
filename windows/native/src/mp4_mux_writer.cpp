#include "mp4_mux_writer.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <filesystem>
#include <limits>
#include <vector>

namespace recorder::mp4 {
using Microsoft::WRL::ComPtr;

namespace {
constexpr std::uint32_t kSampleRate = 48'000;
constexpr std::uint32_t kChannels = 2;
constexpr std::uint32_t kAacFrames = 1'024;
constexpr std::uint64_t kAacDurationNumerator = 10'000'000ULL * kAacFrames;

Error Fail(Error value, std::string* detail, const char* message) {
    if (detail != nullptr) *detail = message;
    return value;
}

HRESULT SetAudioType(IMFMediaType* type, GUID subtype, std::uint32_t bitrate) {
    HRESULT hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    if (SUCCEEDED(hr)) hr = type->SetGUID(MF_MT_SUBTYPE, subtype);
    if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kChannels);
    if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kSampleRate);
    if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
    if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                                            subtype == MFAudioFormat_AAC ? bitrate / 8U : 192'000U);
    if (SUCCEEDED(hr) && subtype == MFAudioFormat_AAC) {
        hr = type->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29U);
    }
    return hr;
}

HRESULT SetVideoType(IMFMediaType* type, GUID subtype, const Config& config) {
    HRESULT hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    if (SUCCEEDED(hr)) hr = type->SetGUID(MF_MT_SUBTYPE, subtype);
    if (SUCCEEDED(hr)) hr = MFSetAttributeSize(type, MF_MT_FRAME_SIZE, config.width, config.height);
    if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(type, MF_MT_FRAME_RATE, config.frame_rate, 1);
    if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    if (SUCCEEDED(hr) && subtype == MFVideoFormat_H264) {
        hr = type->SetUINT32(MF_MT_AVG_BITRATE, config.video_bitrate_bps);
    }
    return hr;
}
}  // namespace

class Writer::Impl {
public:
    ~Impl() {
        sink.Reset();
        if (owns_com_apartment) CoUninitialize();
    }

    HRESULT InitializeApartment() {
        const HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (SUCCEEDED(hr)) owns_com_apartment = true;
        return hr == RPC_E_CHANGED_MODE ? S_OK : hr;
    }

    std::uint64_t NextAudioDuration() const noexcept {
        return (audio_timestamp_remainder + kAacDurationNumerator) / kSampleRate;
    }
    void AdvanceAudio(std::uint64_t duration) noexcept {
        audio_timestamp_remainder = (audio_timestamp_remainder + kAacDurationNumerator) % kSampleRate;
        pending_audio_start += duration;
        ++audio_blocks;
    }

    ComPtr<IMFSinkWriter> sink;
    DWORD video_stream = 0;
    DWORD audio_stream = 0;
    bool owns_com_apartment = false;
    bool begun_writing = false;
    bool has_pending_audio_start = false;
    bool has_video_timestamp = false;
    std::uint64_t pending_audio_start = 0;
    std::uint64_t audio_timestamp_remainder = 0;
    std::uint64_t last_video_timestamp = 0;
    std::uint32_t audio_blocks = 0;
    std::vector<float> pending_audio;
};

Writer::Writer(Config config)
    : config_(std::move(config)),
      partial_path_(config_.final_path.wstring() + L".partial"),
      impl_(std::make_unique<Impl>()) { }

Writer::~Writer() { if (!finalized_) Abort(); }

std::unique_ptr<Writer> Writer::Create(const Config& config, Error* error, std::string* detail) {
    if (error == nullptr) return nullptr;
    *error = Error::InvalidArgument;
    if (config.final_path.empty() || config.width < 2 || config.height < 2 ||
        config.width > 1920 || config.height > 1080 || config.width % 2 != 0 ||
        config.height % 2 != 0 || config.frame_rate == 0 || config.frame_rate > 60 ||
        config.video_bitrate_bps < 250'000 || config.video_bitrate_bps > 20'000'000 ||
        config.audio_bitrate_bps < 64'000 || config.audio_bitrate_bps > 320'000) {
        Fail(Error::InvalidArgument, detail, "Invalid MP4 writer configuration.");
        return nullptr;
    }
    std::error_code filesystem_error;
    if (std::filesystem::exists(config.final_path, filesystem_error) ||
        std::filesystem::exists(config.final_path.wstring() + L".partial", filesystem_error) || filesystem_error) {
        *error = Error::AlreadyExists;
        Fail(Error::AlreadyExists, detail, "Final or partial MP4 output already exists.");
        return nullptr;
    }
    auto writer = std::unique_ptr<Writer>(new Writer(config));
    *error = writer->Open(detail);
    return *error == Error::Ok ? std::move(writer) : nullptr;
}

Error Writer::Open(std::string* detail) {
    HRESULT hr = impl_->InitializeApartment();
    if (FAILED(hr)) return Fail(Error::IoError, detail, "COM initialization failed for MP4 output.");
    ComPtr<IMFAttributes> attributes;
    if (SUCCEEDED(hr)) hr = MFCreateAttributes(&attributes, 1);
    if (SUCCEEDED(hr)) hr = attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4);
    if (SUCCEEDED(hr)) hr = MFCreateSinkWriterFromURL(partial_path_.c_str(), nullptr, attributes.Get(), &impl_->sink);

    ComPtr<IMFMediaType> video_output;
    if (SUCCEEDED(hr)) hr = MFCreateMediaType(&video_output);
    if (SUCCEEDED(hr)) hr = SetVideoType(video_output.Get(), MFVideoFormat_H264, config_);
    if (SUCCEEDED(hr)) hr = impl_->sink->AddStream(video_output.Get(), &impl_->video_stream);

    ComPtr<IMFMediaType> audio_output;
    if (SUCCEEDED(hr)) hr = MFCreateMediaType(&audio_output);
    if (SUCCEEDED(hr)) hr = SetAudioType(audio_output.Get(), MFAudioFormat_AAC, config_.audio_bitrate_bps);
    if (SUCCEEDED(hr)) hr = impl_->sink->AddStream(audio_output.Get(), &impl_->audio_stream);

    ComPtr<IMFMediaType> video_input;
    if (SUCCEEDED(hr)) hr = MFCreateMediaType(&video_input);
    if (SUCCEEDED(hr)) hr = SetVideoType(video_input.Get(), MFVideoFormat_NV12, config_);
    if (SUCCEEDED(hr)) hr = impl_->sink->SetInputMediaType(impl_->video_stream, video_input.Get(), nullptr);

    ComPtr<IMFMediaType> audio_input;
    if (SUCCEEDED(hr)) hr = MFCreateMediaType(&audio_input);
    if (SUCCEEDED(hr)) hr = SetAudioType(audio_input.Get(), MFAudioFormat_PCM, config_.audio_bitrate_bps);
    if (SUCCEEDED(hr)) hr = impl_->sink->SetInputMediaType(impl_->audio_stream, audio_input.Get(), nullptr);
    if (SUCCEEDED(hr)) hr = impl_->sink->BeginWriting();
    if (FAILED(hr)) return Fail(Error::IoError, detail, "Configuring H.264/AAC MP4 encoding failed.");
    impl_->begun_writing = true;
    return Error::Ok;
}

Error Writer::WriteAudioBlock(const float* samples, std::uint64_t timestamp, std::uint64_t duration,
                              std::string* detail) {
    constexpr std::uint64_t bytes = static_cast<std::uint64_t>(kAacFrames) * 4U;
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT hr = MFCreateMemoryBuffer(static_cast<DWORD>(bytes), &buffer);
    BYTE* data = nullptr;
    DWORD maximum = 0;
    if (SUCCEEDED(hr)) hr = buffer->Lock(&data, &maximum, nullptr);
    if (SUCCEEDED(hr) && (data == nullptr || maximum < bytes)) hr = E_FAIL;
    if (SUCCEEDED(hr)) {
        auto* pcm = reinterpret_cast<std::int16_t*>(data);
        for (std::uint64_t index = 0; index < static_cast<std::uint64_t>(kAacFrames) * kChannels; ++index) {
            const auto clamped = (std::max)(-1.0F, (std::min)(1.0F, samples[index]));
            pcm[index] = static_cast<std::int16_t>(clamped * 32767.0F);
        }
    }
    if (data != nullptr) {
        const HRESULT unlock = buffer->Unlock();
        if (SUCCEEDED(hr) && FAILED(unlock)) hr = unlock;
    }
    if (SUCCEEDED(hr)) hr = buffer->SetCurrentLength(static_cast<DWORD>(bytes));
    ComPtr<IMFSample> sample;
    if (SUCCEEDED(hr)) hr = MFCreateSample(&sample);
    if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer.Get());
    if (SUCCEEDED(hr)) hr = sample->SetSampleTime(static_cast<LONGLONG>(timestamp));
    if (SUCCEEDED(hr)) hr = sample->SetSampleDuration(static_cast<LONGLONG>(duration));
    if (SUCCEEDED(hr)) hr = impl_->sink->WriteSample(impl_->audio_stream, sample.Get());
    return FAILED(hr) ? Fail(Error::IoError, detail, "Writing MP4 AAC sample failed.") : Error::Ok;
}

Error Writer::WriteAudioFrames(const float* samples, std::uint32_t frames, std::uint64_t start,
                               std::string* detail) {
    if (samples == nullptr || frames == 0 || finalized_ || aborted_ || !impl_->sink) {
        return Fail(Error::InvalidState, detail, "MP4 writer is not writable.");
    }
    if (!impl_->has_pending_audio_start) {
        impl_->pending_audio_start = start;
        impl_->has_pending_audio_start = true;
    }
    impl_->pending_audio.insert(impl_->pending_audio.end(), samples,
        samples + static_cast<std::size_t>(frames) * kChannels);
    constexpr std::size_t samples_per_block = kAacFrames * kChannels;
    while (impl_->pending_audio.size() >= samples_per_block) {
        const auto duration = impl_->NextAudioDuration();
        if (WriteAudioBlock(impl_->pending_audio.data(), impl_->pending_audio_start, duration, detail) != Error::Ok) return Error::IoError;
        impl_->pending_audio.erase(impl_->pending_audio.begin(), impl_->pending_audio.begin() + samples_per_block);
        impl_->AdvanceAudio(duration);
    }
    return Error::Ok;
}

Error Writer::WriteVideoNv12(const std::uint8_t* bytes, std::uint32_t stride,
                             std::uint64_t timestamp, std::uint64_t duration,
                             std::string* detail) {
    if (bytes == nullptr || stride < config_.width || duration == 0 || finalized_ || aborted_ || !impl_->sink ||
        (impl_->has_video_timestamp && timestamp <= impl_->last_video_timestamp)) {
        return Fail(Error::InvalidState, detail, "MP4 video sample is invalid or non-monotonic.");
    }
    const std::uint64_t source_bytes = static_cast<std::uint64_t>(stride) * config_.height * 3U / 2U;
    const std::uint64_t output_bytes = static_cast<std::uint64_t>(config_.width) * config_.height * 3U / 2U;
    if (source_bytes > std::numeric_limits<DWORD>::max() || output_bytes > std::numeric_limits<DWORD>::max()) {
        return Fail(Error::InvalidArgument, detail, "MP4 video frame is too large.");
    }
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT hr = MFCreateMemoryBuffer(static_cast<DWORD>(output_bytes), &buffer);
    BYTE* destination = nullptr;
    DWORD maximum = 0;
    if (SUCCEEDED(hr)) hr = buffer->Lock(&destination, &maximum, nullptr);
    if (SUCCEEDED(hr) && (destination == nullptr || maximum < output_bytes)) hr = E_FAIL;
    if (SUCCEEDED(hr)) {
        for (std::uint32_t row = 0; row < config_.height; ++row) {
            std::copy_n(bytes + static_cast<std::size_t>(row) * stride, config_.width,
                        destination + static_cast<std::size_t>(row) * config_.width);
        }
        const auto* source_uv = bytes + static_cast<std::size_t>(stride) * config_.height;
        auto* destination_uv = destination + static_cast<std::size_t>(config_.width) * config_.height;
        for (std::uint32_t row = 0; row < config_.height / 2U; ++row) {
            std::copy_n(source_uv + static_cast<std::size_t>(row) * stride, config_.width,
                        destination_uv + static_cast<std::size_t>(row) * config_.width);
        }
    }
    if (destination != nullptr) {
        const HRESULT unlock = buffer->Unlock();
        if (SUCCEEDED(hr) && FAILED(unlock)) hr = unlock;
    }
    if (SUCCEEDED(hr)) hr = buffer->SetCurrentLength(static_cast<DWORD>(output_bytes));
    ComPtr<IMFSample> sample;
    if (SUCCEEDED(hr)) hr = MFCreateSample(&sample);
    if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer.Get());
    if (SUCCEEDED(hr)) hr = sample->SetSampleTime(static_cast<LONGLONG>(timestamp));
    if (SUCCEEDED(hr)) hr = sample->SetSampleDuration(static_cast<LONGLONG>(duration));
    if (SUCCEEDED(hr)) hr = impl_->sink->WriteSample(impl_->video_stream, sample.Get());
    if (FAILED(hr)) return Fail(Error::IoError, detail, "Writing MP4 H.264 sample failed.");
    impl_->last_video_timestamp = timestamp;
    impl_->has_video_timestamp = true;
    return Error::Ok;
}

Error Writer::DrainAudio(std::string* detail) {
    std::array<float, kAacFrames * kChannels> silence{};
    if (!impl_->pending_audio.empty()) {
        std::copy(impl_->pending_audio.begin(), impl_->pending_audio.end(), silence.begin());
        const auto duration = impl_->NextAudioDuration();
        if (WriteAudioBlock(silence.data(), impl_->pending_audio_start, duration, detail) != Error::Ok) return Error::IoError;
        impl_->pending_audio.clear();
        impl_->AdvanceAudio(duration);
    }
    while (impl_->audio_blocks < 3U) {
        const auto duration = impl_->NextAudioDuration();
        if (WriteAudioBlock(silence.data(), impl_->pending_audio_start, duration, detail) != Error::Ok) return Error::IoError;
        impl_->AdvanceAudio(duration);
    }
    return Error::Ok;
}

Error Writer::Finalize(std::string* detail) {
    if (finalized_ || aborted_ || !impl_->sink) return Fail(Error::InvalidState, detail, "MP4 writer cannot finalize.");
    if (!impl_->has_video_timestamp) return Fail(Error::InvalidState, detail, "MP4 output has no video sample.");
    if (DrainAudio(detail) != Error::Ok) return Error::IoError;
    const HRESULT hr = impl_->sink->Finalize();
    if (FAILED(hr)) return Fail(Error::IoError, detail, "Finalizing MP4 output failed.");
    impl_->sink.Reset();
    std::error_code filesystem_error;
    std::filesystem::rename(partial_path_, config_.final_path, filesystem_error);
    if (filesystem_error) return Fail(Error::IoError, detail, "Publishing finalized MP4 output failed.");
    finalized_ = true;
    return Error::Ok;
}

void Writer::Abort() noexcept {
    if (aborted_ || finalized_) return;
    if (impl_) impl_->sink.Reset();
    std::error_code filesystem_error;
    std::filesystem::remove(partial_path_, filesystem_error);
    aborted_ = true;
}

}  // namespace recorder::mp4
