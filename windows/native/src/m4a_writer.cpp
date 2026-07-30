#include "m4a_writer.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <windows.h>
#include <wrl/client.h>

#include <filesystem>
#include <algorithm>
#include <array>
#include <limits>
#include <vector>

namespace recorder::m4a {
using Microsoft::WRL::ComPtr;
class Writer::Impl {
public:
    std::uint64_t NextBlockDuration() const noexcept {
        return (timestamp_remainder + kBlockDurationNumerator) / kSampleRate;
    }

    void AdvanceBlockTimestamp(std::uint64_t duration) noexcept {
        timestamp_remainder =
            (timestamp_remainder + kBlockDurationNumerator) % kSampleRate;
        pending_start_100ns += duration;
        ++written_blocks;
    }

    HRESULT InitializeApartment() {
        const HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (SUCCEEDED(hr)) {
            owns_com_apartment = true;
            return hr;
        }

        return hr;
    }

    ~Impl() {
        // The sink is apartment-affine.  Its final Release must run before
        // balancing the CoInitializeEx performed by this writer.
        sink.Reset();
        if (owns_com_apartment) {
            CoUninitialize();
        }
    }

    ComPtr<IMFSinkWriter> sink;
    bool owns_com_apartment = false;
    std::vector<float> pending_samples;
    std::uint64_t pending_start_100ns = 0;
    std::uint64_t timestamp_remainder = 0;
    std::uint32_t written_blocks = 0;
    bool has_pending_start = false;
    bool begun_writing = false;
    bool finalize_attempted = false;
    bool sink_finalized = false;

private:
    static constexpr std::uint64_t kBlockDurationNumerator =
        10'000'000U * 1024U;
    static constexpr std::uint64_t kSampleRate = 48'000U;
};
namespace {
Error Fail(Error error, std::string* detail, const char* text) { if (detail) *detail = text; return error; }
}
Writer::Writer(std::filesystem::path path, std::uint32_t bitrate) : final_path_(std::move(path)), partial_path_(final_path_.wstring() + L".partial"), bitrate_bps_(bitrate), impl_(std::make_unique<Impl>()) {}
Writer::~Writer() {
    if (!finalized_) Abort();
    // `impl_` tears down the sink and then balances this writer's COM
    // apartment.  Media Foundation itself belongs to the native bridge.
}
std::unique_ptr<Writer> Writer::Create(const std::filesystem::path& path, std::uint32_t bitrate, Error* error, std::string* detail) {
    if (error == nullptr) return nullptr;
    *error = Error::InvalidArgument;
    if (path.empty() || bitrate < 64000 || bitrate > 320000) { Fail(Error::InvalidArgument, detail, "Invalid M4A output path or AAC bitrate."); return nullptr; }
    std::error_code ec;
    if (std::filesystem::exists(path, ec) || std::filesystem::exists(path.wstring() + L".partial", ec) || ec) { Fail(Error::AlreadyExists, detail, "Final or partial M4A output already exists."); *error = Error::AlreadyExists; return nullptr; }
    auto writer = std::unique_ptr<Writer>(new Writer(path, bitrate)); *error = writer->Open(detail); return *error == Error::Ok ? std::move(writer) : nullptr;
}
Error Writer::Open(std::string* detail) {
    HRESULT hr = impl_->InitializeApartment(); if (FAILED(hr)) return Fail(Error::IoError, detail, "COM initialization failed.");
    ComPtr<IMFAttributes> attributes; hr = MFCreateAttributes(&attributes, 1); if (SUCCEEDED(hr)) hr = attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4); if (SUCCEEDED(hr)) hr = MFCreateSinkWriterFromURL(partial_path_.c_str(), nullptr, attributes.Get(), &impl_->sink); if (FAILED(hr)) return Fail(Error::IoError, detail, "Creating M4A sink writer failed.");
    ComPtr<IMFMediaType> output; hr = MFCreateMediaType(&output); if (SUCCEEDED(hr)) hr = output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio); if (SUCCEEDED(hr)) hr = output->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC); if (SUCCEEDED(hr)) hr = output->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2); if (SUCCEEDED(hr)) hr = output->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000); if (SUCCEEDED(hr)) hr = output->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16); if (SUCCEEDED(hr)) hr = output->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, bitrate_bps_ / 8U); if (SUCCEEDED(hr)) hr = output->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29U); DWORD stream = 0; if (SUCCEEDED(hr)) hr = impl_->sink->AddStream(output.Get(), &stream); if (SUCCEEDED(hr) && stream != 0) hr = E_FAIL;
    ComPtr<IMFMediaType> input; if (SUCCEEDED(hr)) hr = MFCreateMediaType(&input); if (SUCCEEDED(hr)) hr = input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio); if (SUCCEEDED(hr)) hr = input->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM); if (SUCCEEDED(hr)) hr = input->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2); if (SUCCEEDED(hr)) hr = input->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000); if (SUCCEEDED(hr)) hr = input->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16); if (SUCCEEDED(hr)) hr = input->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4); if (SUCCEEDED(hr)) hr = input->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192000); if (SUCCEEDED(hr)) hr = impl_->sink->SetInputMediaType(0, input.Get(), nullptr); if (SUCCEEDED(hr)) hr = impl_->sink->BeginWriting(); if (SUCCEEDED(hr)) impl_->begun_writing = true;
    return FAILED(hr) ? Fail(Error::IoError, detail, "Configuring AAC M4A encoding failed.") : Error::Ok;
}
Error Writer::WriteCanonicalBlock(const float* samples, std::uint64_t time,
                                  std::uint64_t duration, std::string* detail) {
    constexpr std::uint32_t kFramesPerWrite = 1024U;
    const std::uint32_t frames = kFramesPerWrite;
    const std::uint64_t bytes64 = static_cast<std::uint64_t>(frames) * 4U;
    ComPtr<IMFMediaBuffer> buffer; HRESULT hr = MFCreateMemoryBuffer(static_cast<DWORD>(bytes64), &buffer); BYTE* data = nullptr; DWORD max = 0; bool locked = false;
    if (SUCCEEDED(hr)) { hr = buffer->Lock(&data, &max, nullptr); locked = SUCCEEDED(hr); }
    if (SUCCEEDED(hr) && (data == nullptr || max < bytes64)) hr = E_FAIL;
    if (SUCCEEDED(hr)) { auto* pcm = reinterpret_cast<std::int16_t*>(data); for (std::uint64_t i = 0; i < static_cast<std::uint64_t>(frames) * 2U; ++i) { const float clamped = (std::max)(-1.0F, (std::min)(1.0F, samples[i])); pcm[i] = static_cast<std::int16_t>(clamped * 32767.0F); } }
    if (locked) { const HRESULT unlock_hr = buffer->Unlock(); if (SUCCEEDED(hr) && FAILED(unlock_hr)) hr = unlock_hr; }
    if (SUCCEEDED(hr)) hr = buffer->SetCurrentLength(static_cast<DWORD>(bytes64)); ComPtr<IMFSample> sample; if (SUCCEEDED(hr)) hr = MFCreateSample(&sample); if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer.Get()); if (SUCCEEDED(hr)) hr = sample->SetSampleTime(static_cast<LONGLONG>(time)); if (SUCCEEDED(hr)) hr = sample->SetSampleDuration(static_cast<LONGLONG>(duration)); if (SUCCEEDED(hr)) hr = impl_->sink->WriteSample(0, sample.Get()); return FAILED(hr) ? Fail(Error::IoError, detail, "Writing AAC sample failed.") : Error::Ok;
}
Error Writer::WriteFrames(const float* samples, std::uint32_t frames, std::uint64_t time, std::string* detail) {
    constexpr std::size_t kSamplesPerWrite = 1024U * 2U;
    if (samples == nullptr || frames == 0U || finalized_ || aborted_ || !impl_ || !impl_->sink) {
        return Fail(Error::InvalidState, detail, "M4A writer is not writable.");
    }
    if (!impl_->has_pending_start) {
        impl_->pending_start_100ns = time;
        impl_->has_pending_start = true;
    }
    impl_->pending_samples.insert(
        impl_->pending_samples.end(), samples,
        samples + static_cast<std::size_t>(frames) * 2U);
    while (impl_->pending_samples.size() >= kSamplesPerWrite) {
        const std::uint64_t duration = impl_->NextBlockDuration();
        const Error result = WriteCanonicalBlock(
            impl_->pending_samples.data(), impl_->pending_start_100ns, duration, detail);
        if (result != Error::Ok) return result;
        impl_->pending_samples.erase(
            impl_->pending_samples.begin(),
            impl_->pending_samples.begin() + static_cast<std::ptrdiff_t>(kSamplesPerWrite));
        impl_->AdvanceBlockTimestamp(duration);
    }
    return Error::Ok;
}
Error Writer::DrainToMinimumAacBlocks(std::string* detail) {
    constexpr std::size_t kSamplesPerWrite = 1024U * 2U;
    constexpr std::uint32_t kMinimumAacBlocksBeforeFinalize = 3U;
    if (!impl_ || !impl_->sink) {
        return Fail(Error::InvalidState, detail, "M4A writer is not writable.");
    }

    std::array<float, kSamplesPerWrite> silence{};
    if (!impl_->pending_samples.empty()) {
        std::copy(
            impl_->pending_samples.begin(), impl_->pending_samples.end(), silence.begin());
        const std::uint64_t duration = impl_->NextBlockDuration();
        const Error result = WriteCanonicalBlock(
            silence.data(), impl_->pending_start_100ns, duration, detail);
        if (result != Error::Ok) return result;
        impl_->AdvanceBlockTimestamp(duration);
        impl_->pending_samples.clear();
        impl_->has_pending_start = false;
    }

    // Windows' AAC sink intermittently fails inside Finalize after a recording
    // with fewer than three complete access units.  Keep three full 1024-frame
    // PCM blocks before Finalize; the added blocks are timestamp-contiguous
    // silence and only cover the encoder's minimum drain/priming requirement.
    while (impl_->written_blocks < kMinimumAacBlocksBeforeFinalize) {
        const std::uint64_t duration = impl_->NextBlockDuration();
        const Error result = WriteCanonicalBlock(
            silence.data(), impl_->pending_start_100ns, duration, detail);
        if (result != Error::Ok) return result;
        impl_->AdvanceBlockTimestamp(duration);
    }
    return Error::Ok;
}
Error Writer::Finalize(std::string* detail) {
    if (finalized_ || aborted_ || !impl_ || !impl_->sink ||
        impl_->finalize_attempted) {
        return Fail(Error::InvalidState, detail, "M4A writer cannot finalize.");
    }
    impl_->finalize_attempted = true;
    if (DrainToMinimumAacBlocks(detail) != Error::Ok) return Error::IoError;
    const HRESULT hr = impl_->sink->Finalize();
    if (FAILED(hr)) return Fail(Error::IoError, detail, "Finalizing M4A output failed.");
    impl_->sink_finalized = true;
    // Close the file handle before the atomic publish.  The sink's final
    // release still occurs on this mixer thread, before its COM apartment is
    // balanced in Impl's destructor.
    impl_->sink.Reset();
    std::error_code ec;
    std::filesystem::rename(partial_path_, final_path_, ec);
    if (ec) return Fail(Error::IoError, detail, "Publishing finalized M4A output failed.");
    finalized_ = true;
    return Error::Ok;
}
void Writer::Abort() noexcept {
    if (aborted_ || finalized_) return;
    const bool preserve_finalized_partial = impl_ && impl_->sink_finalized;
    if (impl_ && impl_->sink && impl_->begun_writing &&
        !impl_->finalize_attempted) {
        // Follow the same primed sink-drain route as Finalize before release.
        // This method is noexcept, so a best-effort drain must never escape.
        try {
            if (DrainToMinimumAacBlocks(nullptr) == Error::Ok) {
                (void)impl_->sink->Finalize();
            }
        } catch (...) {
        }
    }
    if (impl_) impl_->sink.Reset();
    std::error_code ec;
    if (!preserve_finalized_partial) std::filesystem::remove(partial_path_, ec);
    aborted_ = true;
}
}
