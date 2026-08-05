#include "mp4_av_writer.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <filesystem>
#include <limits>
#include <vector>
#include <windows.h>

namespace recorder::mp4 {
using Microsoft::WRL::ComPtr;

namespace {
constexpr std::uint32_t kAudioRate = 48'000U;
constexpr std::uint32_t kAudioChannels = 2U;
constexpr std::uint32_t kAacFrames = 1'024U;
constexpr std::uint64_t kHundredNanoseconds = 10'000'000ULL;

Error Fail(Error error, std::string* detail, const char* text) {
    if (detail != nullptr) *detail = text;
    return error;
}

bool IsValidVideoFormat(const VideoFormat& format) noexcept {
    return format.width >= 16U && format.height >= 16U &&
           (format.width % 2U) == 0U && (format.height % 2U) == 0U &&
           format.frames_per_second > 0U && format.frames_per_second <= 120U &&
           format.bitrate_bps >= 100'000U && format.bitrate_bps <= 50'000'000U;
}
}  // namespace

class AvWriter::Impl final {
public:
    HRESULT InitializeApartment() {
        const HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (SUCCEEDED(result)) owns_com_apartment = true;
        return result;
    }
    ~Impl() {
        sink.Reset();
        if (owns_com_apartment) CoUninitialize();
    }

    ComPtr<IMFSinkWriter> sink;
    std::vector<float> pending_audio;
    std::uint64_t pending_audio_start_100ns = 0;
    std::uint64_t audio_timestamp_remainder = 0;
    bool has_pending_audio_start = false;
    bool begun_writing = false;
    bool finalize_attempted = false;
    bool sink_finalized = false;
    bool owns_com_apartment = false;
};

AvWriter::AvWriter(std::filesystem::path final_path, VideoFormat video,
                   std::uint32_t audio_bitrate_bps)
    : final_path_(std::move(final_path)),
      partial_path_(final_path_.wstring() + L".partial"),
      video_(video),
      audio_bitrate_bps_(audio_bitrate_bps),
      impl_(std::make_unique<Impl>()) {}

AvWriter::~AvWriter() {
    if (!finalized_) Abort();
}

std::unique_ptr<AvWriter> AvWriter::Create(const std::filesystem::path& final_path,
                                           VideoFormat video,
                                           std::uint32_t audio_bitrate_bps,
                                           Error* error, std::string* detail) {
    if (error == nullptr) return nullptr;
    *error = Error::InvalidArgument;
    if (final_path.empty() || !IsValidVideoFormat(video) ||
        audio_bitrate_bps < 64'000U || audio_bitrate_bps > 320'000U) {
        Fail(Error::InvalidArgument, detail, "Invalid MP4 A/V output configuration.");
        return nullptr;
    }
    std::error_code ec;
    if (std::filesystem::exists(final_path, ec) ||
        std::filesystem::exists(final_path.wstring() + L".partial", ec) || ec) {
        Fail(Error::AlreadyExists, detail, "Final or partial MP4 output already exists.");
        *error = Error::AlreadyExists;
        return nullptr;
    }
    auto writer = std::unique_ptr<AvWriter>(new AvWriter(final_path, video, audio_bitrate_bps));
    *error = writer->Open(detail);
    return *error == Error::Ok ? std::move(writer) : nullptr;
}

Error AvWriter::Open(std::string* detail) {
    HRESULT result = impl_->InitializeApartment();
    if (FAILED(result)) return Fail(Error::IoError, detail, "COM initialization failed.");
    ComPtr<IMFAttributes> attributes;
    result = MFCreateAttributes(&attributes, 1U);
    if (SUCCEEDED(result)) result = attributes->SetGUID(
        MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4);
    // File output is driven by our canonical capture clock, not a presentation
    // clock. Without this the sink can throttle AAC while waiting for a static
    // WGC frame and turn a short recorder stop into a long encoder wait.
    if (SUCCEEDED(result)) result = attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
    if (SUCCEEDED(result)) result = MFCreateSinkWriterFromURL(
        partial_path_.c_str(), nullptr, attributes.Get(), &impl_->sink);

    DWORD video_stream = 0;
    ComPtr<IMFMediaType> video_output;
    if (SUCCEEDED(result)) result = MFCreateMediaType(&video_output);
    if (SUCCEEDED(result)) result = video_output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    if (SUCCEEDED(result)) result = video_output->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    if (SUCCEEDED(result)) result = video_output->SetUINT32(MF_MT_AVG_BITRATE, video_.bitrate_bps);
    if (SUCCEEDED(result)) result = MFSetAttributeSize(video_output.Get(), MF_MT_FRAME_SIZE,
                                                        video_.width, video_.height);
    if (SUCCEEDED(result)) result = MFSetAttributeRatio(video_output.Get(), MF_MT_FRAME_RATE,
                                                         video_.frames_per_second, 1U);
    if (SUCCEEDED(result)) result = MFSetAttributeRatio(video_output.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1U, 1U);
    if (SUCCEEDED(result)) result = video_output->SetUINT32(MF_MT_INTERLACE_MODE,
                                                              MFVideoInterlace_Progressive);
    if (SUCCEEDED(result)) result = impl_->sink->AddStream(video_output.Get(), &video_stream);
    if (SUCCEEDED(result) && video_stream != 0U) result = E_FAIL;

    ComPtr<IMFMediaType> video_input;
    if (SUCCEEDED(result)) result = MFCreateMediaType(&video_input);
    if (SUCCEEDED(result)) result = video_input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    // RGB32 is Windows' packed BGRX/BGRA-compatible input. Alpha is ignored.
    if (SUCCEEDED(result)) result = video_input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    if (SUCCEEDED(result)) result = MFSetAttributeSize(video_input.Get(), MF_MT_FRAME_SIZE,
                                                        video_.width, video_.height);
    if (SUCCEEDED(result)) result = MFSetAttributeRatio(video_input.Get(), MF_MT_FRAME_RATE,
                                                         video_.frames_per_second, 1U);
    if (SUCCEEDED(result)) result = MFSetAttributeRatio(video_input.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1U, 1U);
    if (SUCCEEDED(result)) result = video_input->SetUINT32(MF_MT_INTERLACE_MODE,
                                                             MFVideoInterlace_Progressive);
    if (SUCCEEDED(result)) result = impl_->sink->SetInputMediaType(video_stream, video_input.Get(), nullptr);

    DWORD audio_stream = 0;
    ComPtr<IMFMediaType> audio_output;
    if (SUCCEEDED(result)) result = MFCreateMediaType(&audio_output);
    if (SUCCEEDED(result)) result = audio_output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    if (SUCCEEDED(result)) result = audio_output->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
    if (SUCCEEDED(result)) result = audio_output->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kAudioChannels);
    if (SUCCEEDED(result)) result = audio_output->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kAudioRate);
    if (SUCCEEDED(result)) result = audio_output->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16U);
    if (SUCCEEDED(result)) result = audio_output->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                                                             audio_bitrate_bps_ / 8U);
    if (SUCCEEDED(result)) result = audio_output->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29U);
    if (SUCCEEDED(result)) result = impl_->sink->AddStream(audio_output.Get(), &audio_stream);
    if (SUCCEEDED(result) && audio_stream != 1U) result = E_FAIL;

    ComPtr<IMFMediaType> audio_input;
    if (SUCCEEDED(result)) result = MFCreateMediaType(&audio_input);
    if (SUCCEEDED(result)) result = audio_input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    if (SUCCEEDED(result)) result = audio_input->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    if (SUCCEEDED(result)) result = audio_input->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kAudioChannels);
    if (SUCCEEDED(result)) result = audio_input->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kAudioRate);
    if (SUCCEEDED(result)) result = audio_input->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16U);
    if (SUCCEEDED(result)) result = audio_input->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4U);
    if (SUCCEEDED(result)) result = audio_input->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192'000U);
    if (SUCCEEDED(result)) result = impl_->sink->SetInputMediaType(audio_stream, audio_input.Get(), nullptr);
    if (SUCCEEDED(result)) result = impl_->sink->BeginWriting();
    if (SUCCEEDED(result)) impl_->begun_writing = true;
    return FAILED(result) ? Fail(Error::IoError, detail, "Configuring H.264/AAC MP4 encoding failed.") : Error::Ok;
}

Error AvWriter::WriteVideoFrame(const std::uint8_t* bgra, std::size_t byte_count,
                                std::uint64_t start_100ns, std::uint64_t duration_100ns,
                                std::string* detail) {
    const std::uint64_t expected = static_cast<std::uint64_t>(video_.width) * video_.height * 4U;
    if (bgra == nullptr || duration_100ns == 0U || byte_count != expected || finalized_ || aborted_ ||
        !impl_ || !impl_->sink || expected > static_cast<std::uint64_t>((std::numeric_limits<DWORD>::max)())) {
        return Fail(Error::InvalidArgument, detail, "Invalid RGB32 video frame or writer state.");
    }
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT result = MFCreateMemoryBuffer(static_cast<DWORD>(expected), &buffer);
    BYTE* bytes = nullptr;
    DWORD capacity = 0U;
    if (SUCCEEDED(result)) result = buffer->Lock(&bytes, &capacity, nullptr);
    const bool locked = SUCCEEDED(result);
    if (SUCCEEDED(result) && (bytes == nullptr || capacity < expected)) result = E_FAIL;
    if (SUCCEEDED(result)) std::copy(bgra, bgra + byte_count, bytes);
    if (locked) {
        const HRESULT unlock = buffer->Unlock();
        if (SUCCEEDED(result) && FAILED(unlock)) result = unlock;
    }
    if (SUCCEEDED(result)) result = buffer->SetCurrentLength(static_cast<DWORD>(expected));
    ComPtr<IMFSample> sample;
    if (SUCCEEDED(result)) result = MFCreateSample(&sample);
    if (SUCCEEDED(result)) result = sample->AddBuffer(buffer.Get());
    if (SUCCEEDED(result)) result = sample->SetSampleTime(static_cast<LONGLONG>(start_100ns));
    if (SUCCEEDED(result)) result = sample->SetSampleDuration(static_cast<LONGLONG>(duration_100ns));
    if (SUCCEEDED(result)) result = impl_->sink->WriteSample(0U, sample.Get());
    return FAILED(result) ? Fail(Error::IoError, detail, "Writing H.264 video sample failed.") : Error::Ok;
}

Error AvWriter::WriteAudioAccessUnit(const float* samples, std::uint64_t start_100ns,
                                     std::uint64_t duration_100ns, std::string* detail) {
    constexpr std::uint64_t bytes64 = static_cast<std::uint64_t>(kAacFrames) * 4U;
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT result = MFCreateMemoryBuffer(static_cast<DWORD>(bytes64), &buffer);
    BYTE* bytes = nullptr;
    DWORD capacity = 0U;
    if (SUCCEEDED(result)) result = buffer->Lock(&bytes, &capacity, nullptr);
    const bool locked = SUCCEEDED(result);
    if (SUCCEEDED(result) && (bytes == nullptr || capacity < bytes64)) result = E_FAIL;
    if (SUCCEEDED(result)) {
        auto* pcm = reinterpret_cast<std::int16_t*>(bytes);
        for (std::uint64_t index = 0; index < static_cast<std::uint64_t>(kAacFrames) * 2U; ++index) {
            const float clamped = (std::max)(-1.0F, (std::min)(1.0F, samples[index]));
            pcm[index] = static_cast<std::int16_t>(clamped * 32767.0F);
        }
    }
    if (locked) {
        const HRESULT unlock = buffer->Unlock();
        if (SUCCEEDED(result) && FAILED(unlock)) result = unlock;
    }
    if (SUCCEEDED(result)) result = buffer->SetCurrentLength(static_cast<DWORD>(bytes64));
    ComPtr<IMFSample> sample;
    if (SUCCEEDED(result)) result = MFCreateSample(&sample);
    if (SUCCEEDED(result)) result = sample->AddBuffer(buffer.Get());
    if (SUCCEEDED(result)) result = sample->SetSampleTime(static_cast<LONGLONG>(start_100ns));
    if (SUCCEEDED(result)) result = sample->SetSampleDuration(static_cast<LONGLONG>(duration_100ns));
    if (SUCCEEDED(result)) result = impl_->sink->WriteSample(1U, sample.Get());
    return FAILED(result) ? Fail(Error::IoError, detail, "Writing AAC audio sample failed.") : Error::Ok;
}

Error AvWriter::WriteAudioBlock(const float* samples, std::uint32_t frames,
                                std::uint64_t start_100ns, std::string* detail) {
    if (samples == nullptr || frames == 0U || finalized_ || aborted_ || !impl_ || !impl_->sink) {
        return Fail(Error::InvalidState, detail, "MP4 A/V writer is not writable.");
    }
    if (!impl_->has_pending_audio_start) {
        impl_->pending_audio_start_100ns = start_100ns;
        impl_->has_pending_audio_start = true;
    }
    impl_->pending_audio.insert(impl_->pending_audio.end(), samples,
        samples + static_cast<std::size_t>(frames) * kAudioChannels);
    constexpr std::size_t samples_per_access_unit = kAacFrames * kAudioChannels;
    while (impl_->pending_audio.size() >= samples_per_access_unit) {
        const std::uint64_t numerator = impl_->audio_timestamp_remainder + kHundredNanoseconds * kAacFrames;
        const std::uint64_t duration = numerator / kAudioRate;
        const Error write = WriteAudioAccessUnit(impl_->pending_audio.data(), impl_->pending_audio_start_100ns,
                                                 duration, detail);
        if (write != Error::Ok) return write;
        impl_->pending_audio.erase(impl_->pending_audio.begin(),
            impl_->pending_audio.begin() + static_cast<std::ptrdiff_t>(samples_per_access_unit));
        impl_->audio_timestamp_remainder = numerator % kAudioRate;
        impl_->pending_audio_start_100ns += duration;
    }
    return Error::Ok;
}

Error AvWriter::DrainAudio(std::string* detail) {
    constexpr std::size_t samples_per_access_unit = kAacFrames * kAudioChannels;
    if (!impl_ || !impl_->sink) return Fail(Error::InvalidState, detail, "MP4 A/V writer is not writable.");
    if (impl_->pending_audio.empty()) return Error::Ok;
    std::array<float, samples_per_access_unit> padded{};
    std::copy(impl_->pending_audio.begin(), impl_->pending_audio.end(), padded.begin());
    const std::uint64_t numerator = impl_->audio_timestamp_remainder + kHundredNanoseconds * kAacFrames;
    const std::uint64_t duration = numerator / kAudioRate;
    const Error write = WriteAudioAccessUnit(padded.data(), impl_->pending_audio_start_100ns, duration, detail);
    if (write == Error::Ok) {
        impl_->pending_audio.clear();
        impl_->has_pending_audio_start = false;
        impl_->audio_timestamp_remainder = numerator % kAudioRate;
    }
    return write;
}

Error AvWriter::Finalize(std::string* detail) {
    if (finalized_ || aborted_ || !impl_ || !impl_->sink || impl_->finalize_attempted) {
        return Fail(Error::InvalidState, detail, "MP4 A/V writer cannot finalize.");
    }
    impl_->finalize_attempted = true;
    if (DrainAudio(detail) != Error::Ok) return Error::IoError;
    const HRESULT result = impl_->sink->Finalize();
    if (FAILED(result)) return Fail(Error::IoError, detail, "Finalizing MP4 A/V output failed.");
    impl_->sink_finalized = true;
    impl_->sink.Reset();
    std::error_code ec;
    std::filesystem::rename(partial_path_, final_path_, ec);
    if (ec) return Fail(Error::IoError, detail, "Publishing finalized MP4 A/V output failed.");
    finalized_ = true;
    return Error::Ok;
}

Error AvWriter::FinalizeForRecovery(std::string* detail) {
    const Error result = Finalize(detail);
    if (result == Error::Ok) return result;
    preserve_partial_ = true;
    if (impl_) impl_->sink.Reset();
    return result;
}

void AvWriter::Abort() noexcept {
    if (aborted_ || finalized_) return;
    const bool preserve = preserve_partial_ || (impl_ && impl_->sink_finalized);
    if (impl_ && impl_->sink && impl_->begun_writing && !impl_->finalize_attempted) {
        try { (void)DrainAudio(nullptr); (void)impl_->sink->Finalize(); } catch (...) {}
    }
    if (impl_) impl_->sink.Reset();
    std::error_code ec;
    if (!preserve) std::filesystem::remove(partial_path_, ec);
    aborted_ = true;
}

}  // namespace recorder::mp4
