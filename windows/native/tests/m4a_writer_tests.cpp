#include "m4a_writer.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <array>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

#include <windows.h>

namespace {

using recorder::m4a::Error;
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
    std::filesystem::path input_path;
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
        if (argument == "--iterations" || argument == "--frames" || argument == "--input") {
            if (++index >= argc) {
                return false;
            }
            if (argument == "--input") {
                options->input_path = argv[index];
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
        } else if (!have_test && !argument.empty() && argument.front() != '-') {
            options->test = argument;
            have_test = true;
        } else {
            return false;
        }
    }
    return options->iterations <= 10'000U && options->frames <= 48'000U;
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

    Expect(!std::filesystem::exists(final_path) &&
               !std::filesystem::exists(final_path.wstring() + L".partial"),
           "abort-after-write M4A left a session artifact");
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
    Expect(!std::filesystem::exists(final_path) &&
               !std::filesystem::exists(final_path.wstring() + L".partial"),
           "abort-state M4A left a session artifact");
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

}  // namespace

int main(int argc, char** argv) {
    Options options;
    if (!ParseOptions(argc, argv, &options)) {
        return 64;
    }
    std::error_code cleanup_error;
    std::filesystem::path directory;
    try {
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
            } else if (options.test == "runtime") {
                // Intentionally do no writer work: this isolates MFStartup,
                // MFShutdown and COM apartment teardown in a fresh process.
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
    } catch (...) {
        if (!directory.empty()) {
            std::filesystem::remove_all(directory, cleanup_error);
        }
        throw;
    }
    return cleanup_error ? 1 : 0;
}
