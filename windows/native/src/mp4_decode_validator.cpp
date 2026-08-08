#include "mp4_decode_validator.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <windows.h>
#include <wrl/client.h>

#include <filesystem>

namespace recorder::mp4::validation {
namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kVideoStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr DWORD kAudioStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
constexpr std::uint32_t kChannels = 2;
constexpr std::uint32_t kSampleRate = 48'000;

Error Fail(Error error, std::string* detail, const char* message) noexcept {
    if (detail != nullptr) {
        *detail = message;
    }
    return error;
}

class MediaFoundationRuntime final {
public:
    Error Start(std::string* detail) noexcept {
        const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (SUCCEEDED(com)) {
            owns_com_ = true;
        } else if (com != RPC_E_CHANGED_MODE) {
            return Fail(Error::RuntimeInitializationFailed, detail,
                        "COM initialization failed while validating MP4 output.");
        }

        const HRESULT media_foundation = MFStartup(MF_VERSION);
        if (FAILED(media_foundation)) {
            return Fail(Error::RuntimeInitializationFailed, detail,
                        "Media Foundation startup failed while validating MP4 output.");
        }
        started_ = true;
        return Error::Ok;
    }

    ~MediaFoundationRuntime() {
        if (started_) {
            MFShutdown();
        }
        if (owns_com_) {
            CoUninitialize();
        }
    }

private:
    bool owns_com_ = false;
    bool started_ = false;
};

HRESULT ConfigureVideoDecoder(IMFSourceReader* reader) noexcept {
    ComPtr<IMFMediaType> decoded_type;
    HRESULT hr = MFCreateMediaType(&decoded_type);
    if (SUCCEEDED(hr)) {
        hr = decoded_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    }
    if (SUCCEEDED(hr)) {
        hr = decoded_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    }
    if (SUCCEEDED(hr)) {
        hr = reader->SetCurrentMediaType(kVideoStream, nullptr, decoded_type.Get());
    }
    return hr;
}

HRESULT ConfigureAudioDecoder(IMFSourceReader* reader) noexcept {
    ComPtr<IMFMediaType> decoded_type;
    HRESULT hr = MFCreateMediaType(&decoded_type);
    if (SUCCEEDED(hr)) {
        hr = decoded_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    }
    if (SUCCEEDED(hr)) {
        hr = decoded_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    }
    if (SUCCEEDED(hr)) {
        hr = decoded_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kChannels);
    }
    if (SUCCEEDED(hr)) {
        hr = decoded_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kSampleRate);
    }
    if (SUCCEEDED(hr)) {
        hr = decoded_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16U);
    }
    if (SUCCEEDED(hr)) {
        hr = decoded_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4U);
    }
    if (SUCCEEDED(hr)) {
        hr = decoded_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192'000U);
    }
    if (SUCCEEDED(hr)) {
        hr = reader->SetCurrentMediaType(kAudioStream, nullptr, decoded_type.Get());
    }
    return hr;
}

bool HasExpectedNativeType(IMFSourceReader* reader,
                           DWORD stream,
                           const GUID& major_type,
                           const GUID& subtype) noexcept {
    ComPtr<IMFMediaType> native_type;
    GUID actual_major{};
    GUID actual_subtype{};
    return SUCCEEDED(reader->GetNativeMediaType(stream, 0U, &native_type)) &&
           SUCCEEDED(native_type->GetGUID(MF_MT_MAJOR_TYPE, &actual_major)) &&
           SUCCEEDED(native_type->GetGUID(MF_MT_SUBTYPE, &actual_subtype)) &&
           actual_major == major_type && actual_subtype == subtype;
}

bool ReadNonEmptyDecodedSample(IMFSourceReader* reader,
                               DWORD stream,
                               std::uint64_t* decoded_samples) noexcept {
    constexpr std::uint32_t kMaximumReadAttempts = 128U;
    for (std::uint32_t attempt = 0U; attempt < kMaximumReadAttempts; ++attempt) {
        DWORD flags = 0U;
        ComPtr<IMFSample> sample;
        const HRESULT hr = reader->ReadSample(stream, 0U, nullptr, &flags, nullptr, &sample);
        if (FAILED(hr) || (flags & MF_SOURCE_READERF_ERROR) != 0U) {
            return false;
        }
        if (sample != nullptr) {
            ComPtr<IMFMediaBuffer> buffer;
            DWORD bytes = 0U;
            const HRESULT buffer_result = sample->ConvertToContiguousBuffer(&buffer);
            if (FAILED(buffer_result) || buffer == nullptr ||
                FAILED(buffer->GetCurrentLength(&bytes)) || bytes == 0U) {
                return false;
            }
            ++*decoded_samples;
            return true;
        }
        if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0U) {
            return false;
        }
    }
    return false;
}

}  // namespace

Error ProbeDecodableH264AacMp4(const std::filesystem::path& path,
                               Report* report,
                               std::string* detail) noexcept {
    if (report == nullptr || path.empty()) {
        return Fail(Error::InvalidArgument, detail, "MP4 validation requires a path and report.");
    }
    *report = {};
    std::error_code filesystem_error;
    if (!std::filesystem::is_regular_file(path, filesystem_error) || filesystem_error) {
        return Fail(Error::FileNotFound, detail, "MP4 validation input does not exist as a regular file.");
    }

    MediaFoundationRuntime runtime;
    const Error startup = runtime.Start(detail);
    if (startup != Error::Ok) {
        return startup;
    }

    ComPtr<IMFSourceReader> reader;
    const HRESULT open = MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader);
    if (FAILED(open) || reader == nullptr) {
        return Fail(Error::SourceReaderFailed, detail, "Media Foundation could not open finalized MP4 output.");
    }
    if (!HasExpectedNativeType(reader.Get(), kVideoStream, MFMediaType_Video, MFVideoFormat_H264)) {
        return Fail(Error::MissingH264Video, detail, "Finalized MP4 does not expose an H.264 video stream.");
    }
    if (!HasExpectedNativeType(reader.Get(), kAudioStream, MFMediaType_Audio, MFAudioFormat_AAC)) {
        return Fail(Error::MissingAacAudio, detail, "Finalized MP4 does not expose an AAC audio stream.");
    }
    if (FAILED(ConfigureVideoDecoder(reader.Get())) ||
        !ReadNonEmptyDecodedSample(reader.Get(), kVideoStream, &report->decoded_video_samples)) {
        return Fail(Error::VideoDecodeFailed, detail,
                    "Media Foundation could not decode a non-empty H.264 frame from finalized MP4 output.");
    }

    reader.Reset();
    const HRESULT reopen = MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader);
    if (FAILED(reopen) || reader == nullptr) {
        return Fail(Error::SourceReaderFailed, detail,
                    "Media Foundation could not reopen finalized MP4 output for AAC validation.");
    }
    if (FAILED(ConfigureAudioDecoder(reader.Get())) ||
        !ReadNonEmptyDecodedSample(reader.Get(), kAudioStream, &report->decoded_audio_samples)) {
        return Fail(Error::AudioDecodeFailed, detail,
                    "Media Foundation could not decode a non-empty AAC frame from finalized MP4 output.");
    }
    if (detail != nullptr) {
        detail->clear();
    }
    return Error::Ok;
}

Error ProbeDecodableAacM4a(const std::filesystem::path& path,
                           Report* report,
                           std::string* detail) noexcept {
    if (report == nullptr || path.empty()) {
        return Fail(Error::InvalidArgument, detail, "M4A validation requires a path and report.");
    }
    *report = {};
    std::error_code filesystem_error;
    if (!std::filesystem::is_regular_file(path, filesystem_error) || filesystem_error) {
        return Fail(Error::FileNotFound, detail, "M4A validation input does not exist as a regular file.");
    }

    MediaFoundationRuntime runtime;
    const Error startup = runtime.Start(detail);
    if (startup != Error::Ok) return startup;

    ComPtr<IMFSourceReader> reader;
    const HRESULT open = MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader);
    if (FAILED(open) || reader == nullptr) {
        return Fail(Error::SourceReaderFailed, detail, "Media Foundation could not open finalized M4A output.");
    }
    if (!HasExpectedNativeType(reader.Get(), kAudioStream, MFMediaType_Audio, MFAudioFormat_AAC)) {
        return Fail(Error::MissingAacAudio, detail, "Finalized M4A does not expose an AAC audio stream.");
    }
    if (FAILED(ConfigureAudioDecoder(reader.Get())) ||
        !ReadNonEmptyDecodedSample(reader.Get(), kAudioStream, &report->decoded_audio_samples)) {
        return Fail(Error::AudioDecodeFailed, detail,
                    "Media Foundation could not decode a non-empty AAC sample from finalized M4A output.");
    }
    if (detail != nullptr) detail->clear();
    return Error::Ok;
}

}  // namespace recorder::mp4::validation
