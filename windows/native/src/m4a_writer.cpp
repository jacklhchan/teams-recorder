#include "m4a_writer.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <windows.h>
#include <wrl/client.h>

#include <filesystem>
#include <algorithm>
#include <limits>

namespace recorder::m4a {
using Microsoft::WRL::ComPtr;
class Writer::Impl { public: ComPtr<IMFSinkWriter> sink; bool mf_started = false; bool com_initialized = false; };
namespace {
Error Fail(Error error, std::string* detail, const char* text) { if (detail) *detail = text; return error; }
}
Writer::Writer(std::filesystem::path path, std::uint32_t bitrate) : final_path_(std::move(path)), partial_path_(final_path_.wstring() + L".partial"), bitrate_bps_(bitrate), impl_(std::make_unique<Impl>()) {}
Writer::~Writer() {
    if (!finalized_) Abort();
    // IMF objects must be released on their creating thread before MFShutdown.
    // Some AAC sink implementations dereference MF state from their final Release.
    if (impl_) impl_->sink.Reset();
    if (impl_ && impl_->mf_started) MFShutdown();
    if (impl_ && impl_->com_initialized) CoUninitialize();
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
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED); if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return Fail(Error::IoError, detail, "COM initialization failed."); if (SUCCEEDED(hr)) impl_->com_initialized = true;
    hr = MFStartup(MF_VERSION); if (FAILED(hr)) return Fail(Error::IoError, detail, "Media Foundation startup failed."); impl_->mf_started = true;
    ComPtr<IMFAttributes> attributes; hr = MFCreateAttributes(&attributes, 1); if (SUCCEEDED(hr)) hr = attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4); if (SUCCEEDED(hr)) hr = MFCreateSinkWriterFromURL(partial_path_.c_str(), nullptr, attributes.Get(), &impl_->sink); if (FAILED(hr)) return Fail(Error::IoError, detail, "Creating M4A sink writer failed.");
    ComPtr<IMFMediaType> output; hr = MFCreateMediaType(&output); if (SUCCEEDED(hr)) hr = output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio); if (SUCCEEDED(hr)) hr = output->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC); if (SUCCEEDED(hr)) hr = output->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2); if (SUCCEEDED(hr)) hr = output->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000); if (SUCCEEDED(hr)) hr = output->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16); if (SUCCEEDED(hr)) hr = output->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, bitrate_bps_ / 8U); if (SUCCEEDED(hr)) hr = output->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29U); DWORD stream = 0; if (SUCCEEDED(hr)) hr = impl_->sink->AddStream(output.Get(), &stream); if (SUCCEEDED(hr) && stream != 0) hr = E_FAIL;
    ComPtr<IMFMediaType> input; if (SUCCEEDED(hr)) hr = MFCreateMediaType(&input); if (SUCCEEDED(hr)) hr = input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio); if (SUCCEEDED(hr)) hr = input->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM); if (SUCCEEDED(hr)) hr = input->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2); if (SUCCEEDED(hr)) hr = input->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000); if (SUCCEEDED(hr)) hr = input->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16); if (SUCCEEDED(hr)) hr = input->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4); if (SUCCEEDED(hr)) hr = input->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192000); if (SUCCEEDED(hr)) hr = impl_->sink->SetInputMediaType(0, input.Get(), nullptr); if (SUCCEEDED(hr)) hr = impl_->sink->BeginWriting();
    return FAILED(hr) ? Fail(Error::IoError, detail, "Configuring AAC M4A encoding failed.") : Error::Ok;
}
Error Writer::WriteFrames(const float* samples, std::uint32_t frames, std::uint64_t time, std::string* detail) {
    if (samples == nullptr || frames == 0 || finalized_ || aborted_) return Fail(Error::InvalidState, detail, "M4A writer is not writable.");
    const std::uint64_t bytes64 = static_cast<std::uint64_t>(frames) * 4U; if (bytes64 > std::numeric_limits<DWORD>::max()) return Fail(Error::InvalidArgument, detail, "M4A sample block is too large.");
    ComPtr<IMFMediaBuffer> buffer; HRESULT hr = MFCreateMemoryBuffer(static_cast<DWORD>(bytes64), &buffer); BYTE* data = nullptr; DWORD max = 0; if (SUCCEEDED(hr)) hr = buffer->Lock(&data, &max, nullptr); if (SUCCEEDED(hr)) { auto* pcm = reinterpret_cast<std::int16_t*>(data); for (std::uint64_t i = 0; i < static_cast<std::uint64_t>(frames) * 2U; ++i) { const float clamped = (std::max)(-1.0F, (std::min)(1.0F, samples[i])); pcm[i] = static_cast<std::int16_t>(clamped * 32767.0F); } buffer->Unlock(); hr = buffer->SetCurrentLength(static_cast<DWORD>(bytes64)); } ComPtr<IMFSample> sample; if (SUCCEEDED(hr)) hr = MFCreateSample(&sample); if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer.Get()); if (SUCCEEDED(hr)) hr = sample->SetSampleTime(static_cast<LONGLONG>(time)); if (SUCCEEDED(hr)) hr = sample->SetSampleDuration(static_cast<LONGLONG>(frames) * 10000000LL / 48000LL); if (SUCCEEDED(hr)) hr = impl_->sink->WriteSample(0, sample.Get()); return FAILED(hr) ? Fail(Error::IoError, detail, "Writing AAC sample failed.") : Error::Ok;
}
Error Writer::Finalize(std::string* detail) {
    if (finalized_ || aborted_ || !impl_ || !impl_->sink) {
        return Fail(Error::InvalidState, detail, "M4A writer cannot finalize.");
    }
    const HRESULT hr = impl_->sink->Finalize();
    if (FAILED(hr)) return Fail(Error::IoError, detail, "Finalizing M4A output failed.");
    // Close the file handle before the atomic publish.  It also guarantees the
    // sink's final COM Release precedes the eventual MFShutdown in the destructor.
    impl_->sink.Reset();
    std::error_code ec;
    std::filesystem::rename(partial_path_, final_path_, ec);
    if (ec) return Fail(Error::IoError, detail, "Publishing finalized M4A output failed.");
    finalized_ = true;
    return Error::Ok;
}
void Writer::Abort() noexcept { if (aborted_ || finalized_) return; impl_->sink.Reset(); std::error_code ec; std::filesystem::remove(partial_path_, ec); aborted_ = true; }
}
