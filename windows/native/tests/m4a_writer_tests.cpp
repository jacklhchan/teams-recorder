#include "m4a_writer.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <array>
#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include <windows.h>

namespace {

using recorder::m4a::Error;
using recorder::m4a::DurableCheckpoint;
using recorder::m4a::Writer;
using Microsoft::WRL::ComPtr;

class MediaFoundationTestRuntime final {
public:
    MediaFoundationTestRuntime() {
        const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(com_result)) {
            throw std::runtime_error("could not initialize the M4A test COM apartment");
        }
        com_initialized_ = true;

        const HRESULT media_foundation_result = MFStartup(MF_VERSION, MFSTARTUP_FULL);
        if (FAILED(media_foundation_result)) {
            CoUninitialize();
            com_initialized_ = false;
            throw std::runtime_error("could not start Media Foundation for M4A tests");
        }
        media_foundation_started_ = true;
    }

    ~MediaFoundationTestRuntime() {
        // Test writers are destroyed before this fixture, so every AAC sink
        // Release occurs before the shared Media Foundation runtime stops.
        if (media_foundation_started_) {
            MFShutdown();
        }
        if (com_initialized_) {
            CoUninitialize();
        }
    }

    MediaFoundationTestRuntime(const MediaFoundationTestRuntime&) = delete;
    MediaFoundationTestRuntime& operator=(const MediaFoundationTestRuntime&) = delete;

private:
    bool com_initialized_ = false;
    bool media_foundation_started_ = false;
};

void Expect(bool condition, const char* message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

std::filesystem::path TestDirectory() {
    const auto directory = std::filesystem::temp_directory_path() /
        ("teams-recorder-m4a-writer-" + std::to_string(GetCurrentProcessId()));
    std::error_code error;
    std::filesystem::remove_all(directory, error);
    std::filesystem::create_directories(directory, error);
    if (error) {
        throw std::runtime_error("could not create M4A writer test directory");
    }
    return directory;
}

std::vector<unsigned char> ReadBytes(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(input), {}};
}

bool HasTopLevelBox(const std::vector<unsigned char>& bytes, const char* type) {
    std::size_t offset = 0;
    while (offset + 8U <= bytes.size()) {
        const std::uint32_t size =
            (static_cast<std::uint32_t>(bytes[offset]) << 24U) |
            (static_cast<std::uint32_t>(bytes[offset + 1U]) << 16U) |
            (static_cast<std::uint32_t>(bytes[offset + 2U]) << 8U) |
            static_cast<std::uint32_t>(bytes[offset + 3U]);
        if (bytes[offset + 4U] == static_cast<unsigned char>(type[0]) &&
            bytes[offset + 5U] == static_cast<unsigned char>(type[1]) &&
            bytes[offset + 6U] == static_cast<unsigned char>(type[2]) &&
            bytes[offset + 7U] == static_cast<unsigned char>(type[3])) {
            return true;
        }
        if (size < 8U || size > bytes.size() - offset) {
            return false;
        }
        offset += size;
    }
    return false;
}

struct Options {
    std::string test = "container";
    std::uint32_t iterations = 16U;
    std::uint32_t frames = 960U;
    bool diagnostic = false;
    bool hard_exit_after_inspect = false;
    std::filesystem::path input_path;
    std::wstring ready_event_name;
};

bool ParseUnsigned(const char* text, std::uint32_t* value) {
    if (text == nullptr || *text == '\0') {
        return false;
    }
    const char* const end = text + std::char_traits<char>::length(text);
    const auto result = std::from_chars(text, end, *value);
    return result.ec == std::errc{} && result.ptr == end && *value > 0U;
}

bool ParseOptions(int argc, char** argv, Options* options) {
    if (options == nullptr) {
        return false;
    }
    bool have_test = false;
    for (int index = 1; index < argc; ++index) {
        const std::string argument(argv[index]);
        if (argument == "--iterations" || argument == "--frames" || argument == "--input" ||
            argument == "--ready-event") {
            if (++index >= argc) {
                return false;
            }
            if (argument == "--input") {
                options->input_path = argv[index];
                continue;
            }
            if (argument == "--ready-event") {
                const std::string event_name(argv[index]);
                if (event_name.empty() || event_name.size() > 200U ||
                    event_name.find_first_of(" \t\r\n\"") != std::string::npos) {
                    return false;
                }
                options->ready_event_name.assign(event_name.begin(), event_name.end());
                continue;
            }
            std::uint32_t parsed = 0U;
            if (!ParseUnsigned(argv[index], &parsed)) {
                return false;
            }
            if (argument == "--iterations") {
                options->iterations = parsed;
            } else {
                options->frames = parsed;
            }
        } else if (argument == "--diagnostic") {
            options->diagnostic = true;
        } else if (argument == "--hard-exit") {
            options->hard_exit_after_inspect = true;
        } else if (!have_test && !argument.empty() && argument.front() != '-') {
            options->test = argument;
            have_test = true;
        } else {
            return false;
        }
    }
    return options->iterations <= 10'000U && options->frames <= 48'000U &&
        (!options->hard_exit_after_inspect || options->test == "inspect");
}

struct DecodedAudioAnalysis {
    std::uint64_t samples = 0U;
    float peak = 0.0F;
    double rms = 0.0;
};

DecodedAudioAnalysis AnalyzeDecodedAac(const std::filesystem::path& path) {
    Expect(!path.empty() && std::filesystem::exists(path), "inspect input M4A does not exist");
    ComPtr<IMFSourceReader> reader;
    HRESULT result = MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader);
    Expect(SUCCEEDED(result) && reader != nullptr, "inspect could not open M4A");

    constexpr DWORD kAudioStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
    ComPtr<IMFMediaType> pcm_type;
    result = MFCreateMediaType(&pcm_type);
    if (SUCCEEDED(result)) result = pcm_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    if (SUCCEEDED(result)) result = pcm_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    if (SUCCEEDED(result)) result = pcm_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48'000U);
    if (SUCCEEDED(result)) result = pcm_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2U);
    if (SUCCEEDED(result)) result = pcm_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16U);
    if (SUCCEEDED(result)) result = pcm_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4U);
    if (SUCCEEDED(result)) result = pcm_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192'000U);
    if (SUCCEEDED(result)) result = reader->SetCurrentMediaType(kAudioStream, nullptr, pcm_type.Get());
    Expect(SUCCEEDED(result), "inspect could not configure AAC decoding to PCM");

    std::uint64_t samples = 0U;
    float peak = 0.0F;
    double sum_of_squares = 0.0;
    for (;;) {
        DWORD actual_stream = 0U;
        DWORD flags = 0U;
        LONGLONG timestamp = 0;
        ComPtr<IMFSample> sample;
        result = reader->ReadSample(kAudioStream, 0U, &actual_stream, &flags, &timestamp, &sample);
        Expect(SUCCEEDED(result) && (flags & MF_SOURCE_READERF_ERROR) == 0U,
               "inspect could not decode AAC");
        if (sample != nullptr) {
            ComPtr<IMFMediaBuffer> buffer;
            result = sample->ConvertToContiguousBuffer(&buffer);
            DWORD byte_count = 0U;
            if (SUCCEEDED(result)) result = buffer->GetCurrentLength(&byte_count);
            Expect(SUCCEEDED(result) && byte_count % sizeof(std::int16_t) == 0U,
                   "inspect decoder returned malformed PCM");
            BYTE* bytes = nullptr;
            DWORD capacity = 0U;
            result = buffer->Lock(&bytes, &capacity, &byte_count);
            Expect(SUCCEEDED(result), "inspect could not lock decoded PCM");
            for (DWORD offset = 0U; offset < byte_count; offset += sizeof(std::int16_t)) {
                std::int16_t raw = 0;
                std::memcpy(&raw, bytes + offset, sizeof(raw));
                const float value = static_cast<float>(raw) / 32768.0F;
                peak = (std::max)(peak, std::abs(value));
                sum_of_squares += static_cast<double>(value) * value;
                ++samples;
            }
            Expect(SUCCEEDED(buffer->Unlock()), "inspect could not unlock decoded PCM");
        }
        if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0U) {
            break;
        }
    }
    return {samples, peak, samples == 0U ? 0.0 : std::sqrt(sum_of_squares / samples)};
}

void Diagnostic(const Options& options, const char* stage) {
    if (!options.diagnostic) {
        return;
    }
    std::printf("M4A_DIAGNOSTIC:%s\n", stage);
    std::fflush(stdout);
}

void ExpectPublishedContainer(const std::filesystem::path& final_path) {
    const auto bytes = ReadBytes(final_path);
    Expect(bytes.size() > 128U, "finalized M4A is unexpectedly short");
    Expect(HasTopLevelBox(bytes, "ftyp") && HasTopLevelBox(bytes, "mdat") &&
               HasTopLevelBox(bytes, "moov"),
           "finalized M4A is missing a required ISO-BMFF box");
    Expect(!std::filesystem::exists(final_path.wstring() + L".partial"),
           "finalized M4A retained its partial artifact");
}

void ExpectDecodableAacStream(const std::filesystem::path& final_path) {
    ComPtr<IMFSourceReader> reader;
    HRESULT result = MFCreateSourceReaderFromURL(final_path.c_str(), nullptr, &reader);
    Expect(SUCCEEDED(result) && reader != nullptr, "could not open finalized M4A with SourceReader");

    constexpr DWORD kAudioStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
    ComPtr<IMFMediaType> native_type;
    result = reader->GetNativeMediaType(kAudioStream, 0U, &native_type);
    Expect(SUCCEEDED(result) && native_type != nullptr, "M4A has no readable native audio stream");

    GUID subtype = GUID_NULL;
    UINT32 sample_rate = 0U;
    UINT32 channels = 0U;
    Expect(SUCCEEDED(native_type->GetGUID(MF_MT_SUBTYPE, &subtype)) &&
               subtype == MFAudioFormat_AAC,
           "M4A native audio stream is not AAC");
    Expect(SUCCEEDED(native_type->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &sample_rate)) &&
               sample_rate == 48'000U,
           "M4A native audio stream is not 48 kHz");
    Expect(SUCCEEDED(native_type->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels)) && channels == 2U,
           "M4A native audio stream is not stereo");

    ComPtr<IMFMediaType> pcm_type;
    result = MFCreateMediaType(&pcm_type);
    if (SUCCEEDED(result)) result = pcm_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    if (SUCCEEDED(result)) result = pcm_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    if (SUCCEEDED(result)) result = reader->SetCurrentMediaType(kAudioStream, nullptr, pcm_type.Get());
    Expect(SUCCEEDED(result), "SourceReader could not configure AAC decoding to PCM");

    bool decoded_sample = false;
    for (std::uint32_t attempt = 0U; attempt < 32U; ++attempt) {
        DWORD actual_stream = 0U;
        DWORD flags = 0U;
        LONGLONG timestamp = 0;
        ComPtr<IMFSample> sample;
        result = reader->ReadSample(
            kAudioStream, 0U, &actual_stream, &flags, &timestamp, &sample);
        Expect(SUCCEEDED(result) && (flags & MF_SOURCE_READERF_ERROR) == 0U,
               "SourceReader failed while decoding AAC");
        if (sample != nullptr) {
            ComPtr<IMFMediaBuffer> buffer;
            result = sample->ConvertToContiguousBuffer(&buffer);
            DWORD bytes = 0U;
            if (SUCCEEDED(result)) result = buffer->GetCurrentLength(&bytes);
            Expect(SUCCEEDED(result) && bytes > 0U,
                   "SourceReader returned an empty decoded AAC sample");
            decoded_sample = true;
            break;
        }
        if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0U) {
            break;
        }
    }
    Expect(decoded_sample, "SourceReader did not decode an AAC sample");
}

std::uint64_t ReadPresentationDuration100ns(const std::filesystem::path& final_path) {
    ComPtr<IMFSourceReader> reader;
    HRESULT result = MFCreateSourceReaderFromURL(final_path.c_str(), nullptr, &reader);
    Expect(SUCCEEDED(result) && reader != nullptr,
           "could not open finalized M4A to inspect duration");

    PROPVARIANT duration{};
    PropVariantInit(&duration);
    result = reader->GetPresentationAttribute(
        static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE),
        MF_PD_DURATION,
        &duration);
    const bool valid = SUCCEEDED(result) && duration.vt == VT_UI8;
    const std::uint64_t value = valid ? duration.uhVal.QuadPart : 0;
    PropVariantClear(&duration);
    Expect(valid, "M4A presentation duration is unavailable");
    return value;
}

void OneSecondInputRetainsOneSecondTimeline(const std::filesystem::path& directory) {
    const auto final_path = directory / "one-second-duration.m4a";
    Error error = Error::Ok;
    std::string detail;
    auto writer = Writer::Create(final_path, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok,
           "duration writer creation failed");

    std::vector<float> frames(960U * 2U, 0.0F);
    for (std::uint32_t block = 0; block < 50U; ++block) {
        frames[static_cast<std::size_t>(block % 960U) * 2U] = 0.25F;
        Expect(writer->WriteFrames(
                   frames.data(), 960U,
                   static_cast<std::uint64_t>(block) * 200'000ULL,
                   &detail) == Error::Ok,
               "duration writer could not write one-second PCM input");
    }
    Expect(writer->Finalize(&detail) == Error::Ok,
           "duration writer could not finalize");
    writer.reset();

    const std::uint64_t duration = ReadPresentationDuration100ns(final_path);
    Expect(duration >= 9'500'000ULL && duration <= 10'500'000ULL,
           "AAC timestamps compressed a one-second input timeline");
}

void FinalizedFileIsPlayableContainer(const std::filesystem::path& directory,
                                      std::uint32_t frames_per_write) {
    const auto final_path = directory / ("finalized-" + std::to_string(frames_per_write) + ".m4a");
    Error error = Error::Ok;
    std::string detail;
    auto writer = Writer::Create(final_path, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok, "M4A writer creation failed");

    std::vector<float> frames(static_cast<std::size_t>(frames_per_write) * 2U, 0.0F);
    frames[1] = 0.25F;
    Expect(writer->WriteFrames(frames.data(), frames_per_write, 0U, &detail) == Error::Ok,
           "M4A writer could not write PCM frames");
    Expect(writer->Finalize(&detail) == Error::Ok, "M4A writer could not finalize");
    Expect(writer->Finalize(&detail) == Error::InvalidState,
           "M4A writer finalized more than once");

    ExpectPublishedContainer(final_path);
    ExpectDecodableAacStream(final_path);
}

void FinalizedFileRetainsAudiblePcm(const std::filesystem::path& directory) {
    const auto final_path = directory / "audible-signal.m4a";
    Error error = Error::Ok;
    std::string detail;
    auto writer = Writer::Create(final_path, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok, "signal writer creation failed");

    constexpr std::uint32_t kFrames = 960U;
    constexpr std::uint32_t kBlocks = 12U;
    constexpr double kPi = 3.14159265358979323846;
    std::vector<float> frames(static_cast<std::size_t>(kFrames) * 2U);
    for (std::uint32_t block = 0U; block < kBlocks; ++block) {
        for (std::uint32_t frame = 0U; frame < kFrames; ++frame) {
            const auto absolute_frame = static_cast<std::uint64_t>(block) * kFrames + frame;
            const float sample = static_cast<float>(0.45 * std::sin(
                2.0 * kPi * 440.0 * static_cast<double>(absolute_frame) / 48'000.0));
            frames[frame * 2U] = sample;
            frames[frame * 2U + 1U] = sample;
        }
        Expect(writer->WriteFrames(
                   frames.data(), kFrames, static_cast<std::uint64_t>(block) * 200'000U,
                   &detail) == Error::Ok,
               "signal writer could not write PCM frames");
    }
    Expect(writer->Finalize(&detail) == Error::Ok, "signal writer could not finalize");
    writer.reset();

    const DecodedAudioAnalysis analysis = AnalyzeDecodedAac(final_path);
    Expect(analysis.samples > 0U && analysis.peak > 0.05F && analysis.rms > 0.01,
           "AAC output lost all audible PCM energy");
}

void FinalizeWithStages(const std::filesystem::path& directory, const Options& options) {
    const auto final_path = directory / "finalize-diagnostic.m4a";
    Error error = Error::Ok;
    std::string detail;
    Diagnostic(options, "before-writer-create");
    auto writer = Writer::Create(final_path, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok, "M4A finalize diagnostic writer creation failed");
    Diagnostic(options, "after-writer-create");

    std::vector<float> frames(static_cast<std::size_t>(options.frames) * 2U, 0.0F);
    frames[1] = 0.25F;
    Diagnostic(options, "before-write-frames");
    Expect(writer->WriteFrames(frames.data(), options.frames, 0U, &detail) == Error::Ok,
           "M4A finalize diagnostic writer could not write PCM frames");
    Diagnostic(options, "after-write-frames");
    Diagnostic(options, "before-writer-finalize");
    Expect(writer->Finalize(&detail) == Error::Ok,
           "M4A finalize diagnostic writer could not finalize");
    Diagnostic(options, "after-writer-finalize");
    writer.reset();
    Diagnostic(options, "after-writer-reset");
    ExpectPublishedContainer(final_path);
}

void StressWritesFinalizeCleanly(const std::filesystem::path& directory, const Options& options) {
    Error error = Error::Ok;
    std::string detail;
    auto writer = Writer::Create(directory / "stress.m4a", 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok, "M4A stress writer creation failed");
    std::vector<float> frames(static_cast<std::size_t>(options.frames) * 2U, 0.0F);
    for (std::uint32_t index = 0; index < options.iterations; ++index) {
        frames[static_cast<std::size_t>(index % options.frames) * 2U] = 0.25F;
        const std::uint64_t start_100ns =
            static_cast<std::uint64_t>(index) * options.frames * 10'000'000ULL / 48'000ULL;
        Expect(writer->WriteFrames(frames.data(), options.frames, start_100ns, &detail) == Error::Ok,
               "M4A multi-write writer could not write frames");
    }
    Expect(writer->Finalize(&detail) == Error::Ok, "M4A multi-write writer could not finalize");
    ExpectPublishedContainer(directory / "stress.m4a");
}

void SplitWritesFinalizeAndDecode(const std::filesystem::path& directory,
                                  std::uint32_t first_write_frames) {
    const std::uint32_t second_write_frames = first_write_frames == 1U ? 1023U : 64U;
    const auto final_path = directory /
        ("split-" + std::to_string(first_write_frames) + "-" +
         std::to_string(second_write_frames) + ".m4a");
    Error error = Error::Ok;
    std::string detail;
    auto writer = Writer::Create(final_path, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok, "split-write writer creation failed");

    std::vector<float> first(static_cast<std::size_t>(first_write_frames) * 2U, 0.0F);
    std::vector<float> second(static_cast<std::size_t>(second_write_frames) * 2U, 0.0F);
    first[1] = 0.25F;
    second[1] = -0.25F;
    Expect(writer->WriteFrames(first.data(), first_write_frames, 0U, &detail) == Error::Ok,
           "split-write first block failed");
    const std::uint64_t second_start =
        static_cast<std::uint64_t>(first_write_frames) * 10'000'000ULL / 48'000ULL;
    Expect(writer->WriteFrames(second.data(), second_write_frames, second_start, &detail) == Error::Ok,
           "split-write second block failed");
    Expect(writer->Finalize(&detail) == Error::Ok, "split-write writer could not finalize");
    writer.reset();

    ExpectPublishedContainer(final_path);
    ExpectDecodableAacStream(final_path);
}

void AbortRemovesPartialArtifact(const std::filesystem::path& directory) {
    const auto final_path = directory / "aborted.m4a";
    Error error = Error::Ok;
    std::string detail;
    auto writer = Writer::Create(final_path, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok, "abort writer creation failed");
    writer->Abort();
    writer.reset();
    Expect(!std::filesystem::exists(final_path) &&
               !std::filesystem::exists(final_path.wstring() + L".partial"),
           "aborted M4A left a session artifact");
}

void WriteThenAbortRemovesPartialArtifact(const std::filesystem::path& directory,
                                          std::uint32_t frames_per_write) {
    const auto final_path =
        directory / ("aborted-after-write-" + std::to_string(frames_per_write) + ".m4a");
    Error error = Error::Ok;
    std::string detail;
    auto writer = Writer::Create(final_path, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok,
           "abort-after-write writer creation failed");

    std::vector<float> frames(static_cast<std::size_t>(frames_per_write) * 2U, 0.0F);
    frames[1] = 0.25F;
    Expect(writer->WriteFrames(frames.data(), frames_per_write, 0U, &detail) == Error::Ok,
           "abort-after-write writer could not write PCM frames");
    writer->Abort();
    writer.reset();

    const auto partial_path =
        std::filesystem::path(final_path.wstring() + L".partial");
    Expect(!std::filesystem::exists(final_path) &&
               std::filesystem::exists(partial_path),
           "abort-after-write discarded accepted audio evidence");
    ExpectDecodableAacStream(partial_path);
}

void AbortStateIsIdempotentAndClosed(const std::filesystem::path& directory) {
    const auto final_path = directory / "abort-state.m4a";
    Error error = Error::Ok;
    std::string detail;
    auto writer = Writer::Create(final_path, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok, "abort-state writer creation failed");
    const std::array<float, 2U> frame = {0.0F, 0.25F};
    Expect(writer->WriteFrames(frame.data(), 1U, 0U, &detail) == Error::Ok,
           "abort-state writer could not write a short block");
    writer->Abort();
    writer->Abort();
    Expect(writer->WriteFrames(frame.data(), 1U, 0U, &detail) == Error::InvalidState,
           "abort-state writer accepted a write after Abort");
    Expect(writer->Finalize(&detail) == Error::InvalidState,
           "abort-state writer finalized after Abort");
    writer.reset();
    const auto partial_path =
        std::filesystem::path(final_path.wstring() + L".partial");
    Expect(!std::filesystem::exists(final_path) &&
               std::filesystem::exists(partial_path),
           "abort-state discarded accepted audio evidence");
    ExpectDecodableAacStream(partial_path);
}

void PublishFailureRetainsDecodablePartial(const std::filesystem::path& directory) {
    const auto final_path = directory / "publish-blocked.m4a";
    const auto partial_path = std::filesystem::path(final_path.wstring() + L".partial");
    Error error = Error::Ok;
    std::string detail;
    auto writer = Writer::Create(final_path, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok, "retention writer creation failed");

    std::vector<float> frames(960U * 2U, 0.0F);
    frames[1] = 0.25F;
    Expect(writer->WriteFrames(frames.data(), 960U, 0U, &detail) == Error::Ok,
           "retention writer could not write PCM frames");

    std::error_code create_error;
    const bool created_blocker = std::filesystem::create_directory(final_path, create_error);
    Expect(created_blocker && !create_error, "could not create deterministic M4A publish blocker");
    Expect(writer->FinalizeForRecovery(&detail) == Error::IoError,
           "M4A finalization unexpectedly published through a directory blocker");
    writer.reset();

    Expect(std::filesystem::is_directory(final_path),
           "M4A publish blocker was unexpectedly removed");
    Expect(std::filesystem::exists(partial_path),
           "M4A publish failure discarded the recoverable partial artifact");
    ExpectDecodableAacStream(partial_path);
}

void FaultAfterBlocksFinalizesRecoverableBackup(const std::filesystem::path& directory,
                                                const Options& options) {
    const auto session = directory / "manual-fault-after-blocks";
    std::error_code create_error;
    std::filesystem::create_directories(session, create_error);
    Expect(!create_error, "could not create fault-recovery session directory");

    const auto backup_path = session / "recording.audio-backup.m4a";
    const auto recovered_path = session / "recording.m4a";
    Error error = Error::Ok;
    std::string detail;
    auto writer = Writer::Create(backup_path, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok,
           "fault-recovery writer creation failed");

    std::vector<float> frames(960U * 2U, 0.0F);
    for (std::uint32_t block = 0; block < options.iterations; ++block) {
        frames[static_cast<std::size_t>(block % 960U) * 2U] = 0.25F;
        Expect(writer->WriteFrames(
                   frames.data(),
                   960U,
                   static_cast<std::uint64_t>(block) * 200'000U,
                   &detail) == Error::Ok,
               "fault-recovery writer could not write captured audio");
    }

    // Model a source/capture fault after N blocks: ingress has stopped, so
    // this is the single bounded-drain/close path available to the mixer.
    Expect(writer->FinalizeForRecovery(&detail) == Error::Ok,
           "fault-recovery writer could not finalize accumulated audio");
    writer.reset();
    ExpectDecodableAacStream(backup_path);

    // This is the same non-overwriting promotion performed by startup
    // recovery once it sees a valid recording.audio-backup.m4a artifact.
    std::filesystem::rename(backup_path, recovered_path, create_error);
    Expect(!create_error && !std::filesystem::exists(backup_path),
           "startup recovery could not promote the retained backup");
    ExpectDecodableAacStream(recovered_path);
}

void CreateThenAbortCleanly(const std::filesystem::path& directory) {
    Error error = Error::Ok;
    std::string detail;
    auto writer = Writer::Create(directory / "create-only.m4a", 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok, "M4A create-only writer creation failed");
    writer->Abort();
    writer.reset();
    Expect(!std::filesystem::exists(directory / "create-only.m4a") &&
               !std::filesystem::exists(directory / "create-only.m4a.partial"),
           "M4A create-only writer retained an artifact");
}

void ExactSafetyWorkFileFinalizesInPlace(const std::filesystem::path& directory) {
    const auto work_path = directory / "recording.audio-safety.partial.mp4";
    Error error = Error::Ok;
    std::string detail;
    auto writer = Writer::CreateWorkFile(work_path, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok,
           "audio safety exact-work-path writer creation failed");

    std::vector<float> frames(960U * 2U, 0.0F);
    for (std::uint32_t block = 0; block < 100U; ++block) {
        frames[(block * 37U) % frames.size()] = 0.20F;
        Expect(writer->WriteFrames(
                   frames.data(), 960U,
                   static_cast<std::uint64_t>(block) * 200'000U,
                   &detail) == Error::Ok,
               "audio safety exact-work-path write failed");
    }
    DurableCheckpoint checkpoint;
    Expect(writer->CreateDurableCheckpoint(
               20'000'000U, &checkpoint, &detail) == Error::Ok,
           "audio safety marker/byte-stream/file checkpoint failed");
    Expect(checkpoint.sequence == 1U && checkpoint.file_size_bytes > 0U &&
               checkpoint.media_time_100ns == 20'000'000U,
           "audio safety checkpoint evidence was incomplete");
    Expect(writer->Finalize(&detail) == Error::Ok,
           "audio safety exact work file could not finalize");
    writer.reset();

    Expect(std::filesystem::exists(work_path),
           "audio safety exact work file was unexpectedly renamed");
    Expect(!std::filesystem::exists(work_path.wstring() + L".partial"),
           "audio safety exact work mode created a double partial suffix");
    const auto bytes = ReadBytes(work_path);
    Expect(HasTopLevelBox(bytes, "moof"),
           "audio safety exact work file is not fragmented MP4");
    ExpectDecodableAacStream(work_path);
}

constexpr DWORD kWriterChildReadyTimeoutMilliseconds = 20'000U;
constexpr DWORD kChildTerminationTimeoutMilliseconds = 5'000U;
constexpr DWORD kDecodeAnalysisTimeoutMilliseconds = 15'000U;
constexpr std::size_t kMaximumAnalysisOutputBytes = 4U * 1024U;

void ProcessKillDiagnostic(const char* stage) {
    std::fprintf(stderr, "M4A_PROCESS_KILL:%s\n", stage);
    std::fflush(stderr);
}

std::wstring CurrentExecutablePath() {
    wchar_t executable[32'768]{};
    const DWORD executable_length = GetModuleFileNameW(
        nullptr, executable, static_cast<DWORD>(std::size(executable)));
    Expect(executable_length > 0U && executable_length < std::size(executable),
           "kill harness could not resolve its executable path");
    return {executable, executable_length};
}

std::wstring QuoteCommandArgument(const std::wstring& value) {
    // Test paths and event names are generated locally and cannot contain a
    // quote. Rejecting that shape is safer than attempting a partial command
    // line escaping implementation in this kill harness.
    Expect(!value.empty() && value.find(L'"') == std::wstring::npos,
           "kill harness command argument is invalid");
    return L"\"" + value + L"\"";
}

void WriteKillChildReadyMarker(
    const std::filesystem::path& path,
    const DurableCheckpoint& checkpoint) {
    const std::filesystem::path temporary_path(path.wstring() + L".tmp");
    const HANDLE file = CreateFileW(
        temporary_path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    Expect(file != INVALID_HANDLE_VALUE,
           "kill child could not create its durable ready marker");
    std::array<char, 256U> evidence{};
    const int evidence_length = std::snprintf(
        evidence.data(), evidence.size(),
        "sequence=%llu\nbytes=%llu\ncheckpoint100ns=%llu\naccepted100ns=190000000\n",
        static_cast<unsigned long long>(checkpoint.sequence),
        static_cast<unsigned long long>(checkpoint.file_size_bytes),
        static_cast<unsigned long long>(checkpoint.media_time_100ns));
    Expect(evidence_length > 0 &&
               static_cast<std::size_t>(evidence_length) < evidence.size(),
           "kill child checkpoint evidence exceeded its bounded marker");
    DWORD written = 0;
    const bool write_ok = WriteFile(
        file, evidence.data(), static_cast<DWORD>(evidence_length),
        &written, nullptr) != FALSE;
    const bool flush_ok = write_ok && written == static_cast<DWORD>(evidence_length) &&
        FlushFileBuffers(file) != FALSE;
    CloseHandle(file);
    if (!flush_ok) {
        (void)DeleteFileW(temporary_path.c_str());
        Expect(false, "kill child could not flush its ready marker");
    }
    const bool published = MoveFileExW(
        temporary_path.c_str(), path.c_str(),
        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
    if (!published) {
        (void)DeleteFileW(temporary_path.c_str());
    }
    Expect(published, "kill child could not atomically publish its ready marker");
}

void SignalKillChildReadyEvent(const std::wstring& event_name) {
    const HANDLE ready_event = OpenEventW(
        EVENT_MODIFY_STATE, FALSE, event_name.c_str());
    Expect(ready_event != nullptr,
           "kill child could not open the parent readiness event");
    const bool signaled = SetEvent(ready_event) != FALSE;
    CloseHandle(ready_event);
    Expect(signaled, "kill child could not signal the parent readiness event");
}

[[noreturn]] void RunCheckpointKillChild(
    const std::filesystem::path& directory,
    const std::wstring& ready_event_name) {
    Expect(!directory.empty() && std::filesystem::exists(directory),
           "kill child did not receive its parent-owned directory");
    Expect(!ready_event_name.empty(),
           "kill child did not receive a readiness event name");
    const auto work_path = directory / "recording.audio-safety.partial.mp4";
    Error error = Error::Ok;
    std::string detail;
    auto writer = Writer::CreateWorkFile(work_path, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok,
           "kill child could not create the audio safety writer");

    std::vector<float> frames(960U * 2U, 0.0F);
    DurableCheckpoint last_checkpoint;
    for (std::uint32_t block = 0; block < 950U; ++block) {
        frames[(static_cast<std::size_t>(block) * 53U) % frames.size()] = 0.15F;
        Expect(writer->WriteFrames(
                   frames.data(), 960U,
                   static_cast<std::uint64_t>(block) * 200'000U,
                   &detail) == Error::Ok,
               "kill child could not write audio");
        const std::uint32_t completed_blocks = block + 1U;
        if (completed_blocks == 100U || completed_blocks == 500U) {
            DurableCheckpoint checkpoint;
            const std::uint64_t media_time =
                static_cast<std::uint64_t>(completed_blocks) * 200'000U;
            Expect(writer->CreateDurableCheckpoint(
                       media_time, &checkpoint, &detail) == Error::Ok,
                   "kill child durable checkpoint failed");
            const std::uint64_t expected_sequence =
                completed_blocks == 100U ? 1U : 2U;
            Expect(checkpoint.sequence == expected_sequence &&
                       checkpoint.file_size_bytes > 0U &&
                       checkpoint.media_time_100ns == media_time,
                   "kill child checkpoint evidence was incomplete");
            last_checkpoint = checkpoint;
        }
    }

    // The last declared durable checkpoint is 10 seconds. The child has
    // accepted another 9 seconds when the parent kills it, so an EOS-decodable
    // prefix of at least 9 seconds proves the advertised <=10 second tail.
    Expect(last_checkpoint.sequence == 2U,
           "kill child did not retain its second checkpoint");
    WriteKillChildReadyMarker(
        directory / "checkpoint.ready", last_checkpoint);
    SignalKillChildReadyEvent(ready_event_name);
    Sleep(INFINITE);
    std::terminate();
}

struct KillCheckpointEvidence {
    std::uint64_t sequence = 0;
    std::uint64_t bytes = 0;
    std::uint64_t checkpoint_100ns = 0;
    std::uint64_t accepted_100ns = 0;
};

std::uint64_t ParseBoundedEvidenceField(
    std::string_view evidence, std::string_view key) {
    const std::size_t offset = evidence.find(key);
    Expect(offset != std::string_view::npos,
           "kill checkpoint marker is missing a required field");
    const std::size_t value_start = offset + key.size();
    const std::size_t value_end = evidence.find('\n', value_start);
    Expect(value_end != std::string_view::npos && value_end > value_start,
           "kill checkpoint marker contains a malformed field");
    std::uint64_t value = 0;
    const char* begin = evidence.data() + value_start;
    const char* end = evidence.data() + value_end;
    const auto parsed = std::from_chars(begin, end, value);
    Expect(parsed.ec == std::errc{} && parsed.ptr == end,
           "kill checkpoint marker contains a non-numeric field");
    return value;
}

KillCheckpointEvidence ReadKillCheckpointEvidence(
    const std::filesystem::path& path) {
    const auto bytes = ReadBytes(path);
    Expect(!bytes.empty() && bytes.size() <= 255U,
           "kill checkpoint marker exceeds its bounded format");
    const std::string_view evidence(
        reinterpret_cast<const char*>(bytes.data()), bytes.size());
    return {
        ParseBoundedEvidenceField(evidence, "sequence="),
        ParseBoundedEvidenceField(evidence, "bytes="),
        ParseBoundedEvidenceField(evidence, "checkpoint100ns="),
        ParseBoundedEvidenceField(evidence, "accepted100ns="),
    };
}

void CopyDurablePrefix(
    const std::filesystem::path& source,
    const std::filesystem::path& candidate,
    std::uint64_t byte_count) {
    Expect(byte_count > 0U && byte_count <= std::filesystem::file_size(source),
           "durable checkpoint byte offset is outside the killed work file");
    std::ifstream input(source, std::ios::binary);
    std::ofstream output(candidate, std::ios::binary | std::ios::trunc);
    Expect(input.good() && output.good(),
           "kill harness could not open its durable prefix files");
    std::array<char, 64U * 1024U> buffer{};
    std::uint64_t remaining = byte_count;
    while (remaining > 0U) {
        const auto amount = static_cast<std::streamsize>((std::min)(
            remaining, static_cast<std::uint64_t>(buffer.size())));
        input.read(buffer.data(), amount);
        Expect(input.gcount() == amount,
               "killed work file ended before its durable checkpoint offset");
        output.write(buffer.data(), amount);
        Expect(output.good(), "writing the durable prefix candidate failed");
        remaining -= static_cast<std::uint64_t>(amount);
    }
    output.flush();
    Expect(output.good(), "flushing the durable prefix candidate failed");
}

std::uint64_t ParseAnalysisField(
    std::string_view output,
    std::string_view key) {
    const std::size_t offset = output.find(key);
    Expect(offset != std::string_view::npos,
           "decode analysis output is missing a required field");
    const std::size_t value_start = offset + key.size();
    std::size_t value_end = value_start;
    while (value_end < output.size() && output[value_end] >= '0' &&
           output[value_end] <= '9') {
        ++value_end;
    }
    Expect(value_end > value_start,
           "decode analysis output contains a malformed numeric field");
    std::uint64_t value = 0U;
    const auto parsed = std::from_chars(
        output.data() + value_start, output.data() + value_end, value);
    Expect(parsed.ec == std::errc{} && parsed.ptr == output.data() + value_end,
           "decode analysis output contains a non-numeric field");
    return value;
}

void TerminateBoundedChild(HANDLE process, DWORD exit_code,
                           const char* failure_message) {
    Expect(process != nullptr, "bounded child process handle is invalid");
    Expect(TerminateProcess(process, exit_code) != FALSE, failure_message);
    Expect(WaitForSingleObject(
               process, kChildTerminationTimeoutMilliseconds) == WAIT_OBJECT_0,
           "bounded child did not terminate promptly");
}

DecodedAudioAnalysis AnalyzeDecodedAacInBoundedChild(
    const std::wstring& executable,
    const std::filesystem::path& candidate_path,
    const std::filesystem::path& directory) {
    const auto output_path = directory / "decode-analysis.txt";
    SECURITY_ATTRIBUTES inheritable{};
    inheritable.nLength = sizeof(inheritable);
    inheritable.bInheritHandle = TRUE;
    const HANDLE output_file = CreateFileW(
        output_path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, &inheritable,
        CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    Expect(output_file != INVALID_HANDLE_VALUE,
           "could not create bounded decode-analysis output");
    const HANDLE input = CreateFileW(
        L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
        &inheritable, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (input == INVALID_HANDLE_VALUE) {
        CloseHandle(output_file);
        Expect(false, "could not create bounded decode-analysis input");
    }

    std::wstring command = QuoteCommandArgument(executable);
    command += L" inspect --input ";
    command += QuoteCommandArgument(candidate_path.wstring());
    // The child flushes its one bounded result line and exits directly. This
    // deliberately isolates any CI-only MFShutdown stall from the parent
    // kill/recovery test while retaining a real SourceReader EOS traversal.
    command += L" --diagnostic --hard-exit";
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = input;
    startup.hStdOutput = output_file;
    startup.hStdError = output_file;
    PROCESS_INFORMATION process{};
    const BOOL created = CreateProcessW(
        nullptr, command.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
        nullptr, nullptr, &startup, &process);
    CloseHandle(input);
    CloseHandle(output_file);
    Expect(created != FALSE,
           "could not start bounded decode-analysis child");

    const DWORD wait = WaitForSingleObject(
        process.hProcess, kDecodeAnalysisTimeoutMilliseconds);
    if (wait == WAIT_TIMEOUT) {
        ProcessKillDiagnostic("decode-analysis-timeout");
        TerminateBoundedChild(
            process.hProcess, 198U,
            "could not terminate a timed-out decode-analysis child");
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        throw std::runtime_error(
            "decode-analysis child exceeded its internal 15-second timeout");
    }
    if (wait != WAIT_OBJECT_0) {
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        throw std::runtime_error("waiting for the decode-analysis child failed");
    }
    DWORD exit_code = 0U;
    const bool have_exit_code = GetExitCodeProcess(
        process.hProcess, &exit_code) != FALSE;
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    Expect(have_exit_code && exit_code == 0U,
           "decode-analysis child failed before it reached end-of-stream");

    std::error_code size_error;
    const std::uintmax_t output_size = std::filesystem::file_size(
        output_path, size_error);
    Expect(!size_error && output_size > 0U &&
               output_size <= kMaximumAnalysisOutputBytes,
           "decode-analysis child output exceeded its bounded protocol");
    const auto bytes = ReadBytes(output_path);
    Expect(bytes.size() == output_size,
           "decode-analysis child output could not be read completely");
    const std::string_view output(
        reinterpret_cast<const char*>(bytes.data()), bytes.size());
    const std::uint64_t samples = ParseAnalysisField(
        output, "M4A_ANALYSIS: samples=");
    Expect(samples > 0U && samples % 2U == 0U,
           "decode-analysis child produced an invalid PCM sample count");
    return {samples, 0.0F, 0.0};
}

void ProcessKillRetainsDecodableCheckpoint(const std::filesystem::path& directory) {
    const std::wstring executable = CurrentExecutablePath();
    const std::wstring ready_event_name =
        L"Local\\TeamsRecorderM4aKillReady-" +
        std::to_wstring(GetCurrentProcessId()) + L"-" +
        std::to_wstring(GetTickCount64());
    const HANDLE ready_event = CreateEventW(
        nullptr, TRUE, FALSE, ready_event_name.c_str());
    Expect(ready_event != nullptr,
           "kill harness could not create its readiness event");

    std::wstring command = QuoteCommandArgument(executable);
    command += L" kill-child --input ";
    command += QuoteCommandArgument(directory.wstring());
    command += L" --ready-event ";
    command += QuoteCommandArgument(ready_event_name);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    const BOOL created = CreateProcessW(
               nullptr, command.data(), nullptr, nullptr, FALSE,
               CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process);
    if (created == FALSE) {
        CloseHandle(ready_event);
        Expect(false, "kill harness could not start its writer child");
    }
    ProcessKillDiagnostic("writer-child-started");

    bool child_terminated = false;
    const auto cleanup = [&] {
        if (!child_terminated) {
            (void)TerminateProcess(process.hProcess, 199U);
            (void)WaitForSingleObject(
                process.hProcess, kChildTerminationTimeoutMilliseconds);
            child_terminated = true;
        }
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        CloseHandle(ready_event);
    };

    try {
        const auto ready_path = directory / "checkpoint.ready";
        const HANDLE wait_handles[] = {process.hProcess, ready_event};
        const DWORD readiness = WaitForMultipleObjects(
            static_cast<DWORD>(std::size(wait_handles)), wait_handles, FALSE,
            kWriterChildReadyTimeoutMilliseconds);
        if (readiness == WAIT_TIMEOUT) {
            ProcessKillDiagnostic("writer-child-ready-timeout");
            throw std::runtime_error(
                "writer child exceeded its internal 20-second readiness timeout");
        }
        if (readiness == WAIT_OBJECT_0) {
            DWORD exit_code = 0U;
            const bool have_exit_code = GetExitCodeProcess(
                process.hProcess, &exit_code) != FALSE;
            throw std::runtime_error(
                have_exit_code
                    ? "kill writer child exited before publishing checkpoint evidence"
                    : "could not obtain the pre-readiness child exit code");
        }
        Expect(readiness == WAIT_OBJECT_0 + 1U,
               "waiting for the writer child readiness event failed");
        Expect(std::filesystem::exists(ready_path),
               "writer child signaled readiness without a marker");
        ProcessKillDiagnostic("writer-child-ready");
        Expect(WaitForSingleObject(process.hProcess, 0U) == WAIT_TIMEOUT,
               "kill writer child exited at the readiness boundary");
        TerminateBoundedChild(
            process.hProcess, 197U,
            "TerminateProcess failed for the checkpoint child");
        child_terminated = true;
        DWORD exit_code = 0;
        Expect(GetExitCodeProcess(process.hProcess, &exit_code) != FALSE &&
                   exit_code == 197U,
               "checkpoint child was not killed at the intended boundary");
        const auto evidence = ReadKillCheckpointEvidence(ready_path);
        Expect(evidence.sequence == 2U &&
                   evidence.checkpoint_100ns == 100'000'000ULL &&
                   evidence.accepted_100ns == 190'000'000ULL,
               "kill checkpoint marker does not describe the intended boundary");
        const auto work_path = directory / "recording.audio-safety.partial.mp4";
        const auto candidate_path = directory / "recovered-prefix.mp4";
        CopyDurablePrefix(work_path, candidate_path, evidence.bytes);
        const auto candidate_bytes = ReadBytes(candidate_path);
        Expect(HasTopLevelBox(candidate_bytes, "ftyp") &&
                   HasTopLevelBox(candidate_bytes, "moov") &&
                   HasTopLevelBox(candidate_bytes, "moof") &&
                   HasTopLevelBox(candidate_bytes, "mdat"),
                   "durable audio safety prefix is not fragmented MP4");
        ProcessKillDiagnostic("decode-analysis-started");
        const DecodedAudioAnalysis analysis = AnalyzeDecodedAacInBoundedChild(
            executable, candidate_path, directory);
        ProcessKillDiagnostic("decode-analysis-complete");
        const std::uint64_t decoded_frames = analysis.samples / 2U;
        const std::uint64_t decoded_duration_100ns =
            decoded_frames * 10'000'000ULL / 48'000ULL;
        constexpr std::uint64_t kMaximumTailLoss100ns = 100'000'000ULL;
        Expect(decoded_duration_100ns >= 95'000'000ULL &&
                   decoded_duration_100ns <= 105'000'000ULL &&
                   decoded_duration_100ns + kMaximumTailLoss100ns >=
                       evidence.accepted_100ns,
               "durable prefix duration or 10-second tail-loss bound failed");
        cleanup();
    } catch (...) {
        cleanup();
        throw;
    }
}

}  // namespace

int main(int argc, char** argv) {
    Options options;
    if (!ParseOptions(argc, argv, &options)) {
        return 64;
    }
    std::error_code cleanup_error;
    std::filesystem::path directory;
    try {
        // Keep the parent process free of Media Foundation.  This makes the
        // true external-kill test independent of a CI-only MFShutdown stall;
        // the writer and the SourceReader EOS proof each still run in their
        // own bounded child process.
        if (options.test == "process-kill") {
            directory = TestDirectory();
            ProcessKillRetainsDecodableCheckpoint(directory);
            std::filesystem::remove_all(directory, cleanup_error);
            directory.clear();
            return cleanup_error ? 1 : 0;
        }
        Diagnostic(options, "before-runtime-startup");
        {
            MediaFoundationTestRuntime media_foundation;
            Diagnostic(options, "after-runtime-startup");
            if (options.test == "inspect") {
                const DecodedAudioAnalysis analysis = AnalyzeDecodedAac(options.input_path);
                std::printf("M4A_ANALYSIS: samples=%llu frames=%llu peak=%.6f rms=%.6f\n",
                            static_cast<unsigned long long>(analysis.samples),
                            static_cast<unsigned long long>(analysis.samples / 2U),
                            analysis.peak, analysis.rms);
                if (options.hard_exit_after_inspect) {
                    std::fflush(stdout);
                    // The bounded process has emitted its complete protocol
                    // line. Avoid allowing a CI-specific MF shutdown hang to
                    // consume the parent recovery test's CTest budget.
                    ExitProcess(0);
                }
            } else if (options.test == "runtime") {
                // Intentionally do no writer work: this isolates MFStartup,
                // MFShutdown and COM apartment teardown in a fresh process.
            } else if (options.test == "kill-child") {
                RunCheckpointKillChild(options.input_path, options.ready_event_name);
            } else {
                directory = TestDirectory();
                Diagnostic(options, "before-writer-work");
                if (options.test == "container" || options.test == "tail") {
                    FinalizedFileIsPlayableContainer(directory, options.frames);
                } else if (options.test == "signal") {
                    FinalizedFileRetainsAudiblePcm(directory);
                } else if (options.test == "finalize") {
                    FinalizeWithStages(directory, options);
                } else if (options.test == "stress") {
                    StressWritesFinalizeCleanly(directory, options);
                } else if (options.test == "duration") {
                    OneSecondInputRetainsOneSecondTimeline(directory);
                } else if (options.test == "split") {
                    SplitWritesFinalizeAndDecode(directory, options.frames);
                } else if (options.test == "abort") {
                    AbortRemovesPartialArtifact(directory);
                } else if (options.test == "abort-after-write") {
                    WriteThenAbortRemovesPartialArtifact(directory, options.frames);
                } else if (options.test == "abort-state") {
                    AbortStateIsIdempotentAndClosed(directory);
                } else if (options.test == "publish-failure") {
                    PublishFailureRetainsDecodablePartial(directory);
                } else if (options.test == "fault-after") {
                    FaultAfterBlocksFinalizesRecoverableBackup(directory, options);
                } else if (options.test == "create") {
                    CreateThenAbortCleanly(directory);
                } else if (options.test == "work-file") {
                    ExactSafetyWorkFileFinalizesInPlace(directory);
                } else {
                    return 64;
                }
                Diagnostic(options, "after-writer-destruction");
                std::filesystem::remove_all(directory, cleanup_error);
                directory.clear();
                if (cleanup_error) {
                    return 1;
                }
            }
            Diagnostic(options, "before-runtime-shutdown");
        }
        Diagnostic(options, "after-runtime-shutdown");
    } catch (const std::exception& exception) {
        if (!directory.empty()) {
            std::filesystem::remove_all(directory, cleanup_error);
        }
        std::fprintf(stderr, "FAIL M4A writer test (%s): %s\n",
                     options.test.c_str(), exception.what());
        std::fflush(stderr);
        return 1;
    } catch (...) {
        if (!directory.empty()) {
            std::filesystem::remove_all(directory, cleanup_error);
        }
        std::fprintf(stderr, "FAIL M4A writer test (%s): unknown exception\n",
                     options.test.c_str());
        std::fflush(stderr);
        return 1;
    }
    return cleanup_error ? 1 : 0;
}
