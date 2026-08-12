#include "mp4_mux_writer.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

// Deterministic native acceptance harness for AT-03 / AT-05.
//
// It writes a short (by default) H.264/AAC MP4 through the production
// Mp4MuxWriter, with full-frame white flashes and 1 kHz audio beeps on the
// same canonical timestamps.  It then reopens and seeks the result with
// Media Foundation, decodes both streams, checks nondecreasing presentation
// timestamps, and requires every A/V marker to agree within 80 ms.
//
// Run a five-minute AT-03 exercise with:
//   Recorder.AvMarkerAcceptance.Tests --duration-seconds 300

namespace {

using Microsoft::WRL::ComPtr;

constexpr std::uint64_t kHundredNanosecondsPerSecond = 10'000'000ULL;
constexpr std::uint64_t kMaximumAvMarkerOffset100ns = 800'000ULL;
constexpr std::uint64_t kMarkerAssociationWindow100ns = 4'000'000ULL;
constexpr std::uint64_t kFlashDuration100ns = 2'000'000ULL;
constexpr std::uint64_t kBeepDuration100ns = 2'000'000ULL;
constexpr std::uint64_t kSeekLead100ns = 5'000'000ULL;
constexpr std::uint64_t kSeekSearchWindow100ns = 10'000'000ULL;
constexpr std::uint32_t kWidth = 320U;
constexpr std::uint32_t kHeight = 180U;
constexpr std::uint32_t kFrameRate = 30U;
constexpr std::uint32_t kSampleRate = 48'000U;
constexpr std::uint32_t kChannels = 2U;
constexpr std::uint32_t kAudioWriteFrames = 960U;
constexpr std::uint32_t kDefaultDurationSeconds = 8U;
constexpr std::uint32_t kMinimumDurationSeconds = 4U;
constexpr std::uint32_t kMaximumDurationSeconds = 3'600U;
constexpr std::uint32_t kMaximumReadAttempts = 512U;
constexpr double kBeepFrequencyHz = 1'000.0;
constexpr double kBeepAmplitude = 0.80;
constexpr double kBeepMeanMagnitudeThreshold = 1'200.0;
constexpr double kFlashAverageLumaThreshold = 128.0;
constexpr double kPi = 3.141592653589793238462643383279502884;

[[noreturn]] void Fail(const std::string& message) {
    throw std::runtime_error(message);
}

void Expect(bool condition, const char* message) {
    if (!condition) {
        Fail(message);
    }
}

void ExpectHr(HRESULT value, const char* message) {
    if (FAILED(value)) {
        Fail(message);
    }
}

std::uint64_t TimestampDistance(std::uint64_t left, std::uint64_t right) {
    return left >= right ? left - right : right - left;
}

std::string FormatTimestamp(std::uint64_t timestamp) {
    return std::to_string(timestamp) + " (100ns)";
}

class MediaFoundationRuntime final {
public:
    MediaFoundationRuntime() {
        const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (SUCCEEDED(com)) {
            owns_com_apartment_ = true;
        } else if (com != RPC_E_CHANGED_MODE) {
            Fail("CoInitializeEx failed for the A/V marker acceptance harness.");
        }

        const HRESULT media_foundation = MFStartup(MF_VERSION);
        if (FAILED(media_foundation)) {
            Fail("MFStartup failed for the A/V marker acceptance harness.");
        }
        started_ = true;
    }

    ~MediaFoundationRuntime() {
        if (started_) {
            MFShutdown();
        }
        if (owns_com_apartment_) {
            CoUninitialize();
        }
    }

    MediaFoundationRuntime(const MediaFoundationRuntime&) = delete;
    MediaFoundationRuntime& operator=(const MediaFoundationRuntime&) = delete;

private:
    bool owns_com_apartment_ = false;
    bool started_ = false;
};

class TestArtifact final {
public:
    TestArtifact() {
        root_ = std::filesystem::temp_directory_path() /
                ("teams-recorder-av-marker-" + std::to_string(GetCurrentProcessId()));
        std::error_code error;
        std::filesystem::remove_all(root_, error);
        if (error) {
            Fail("Could not clear the deterministic A/V marker test directory.");
        }
        std::filesystem::create_directories(root_, error);
        if (error) {
            Fail("Could not create the deterministic A/V marker test directory.");
        }
    }

    ~TestArtifact() {
        if (succeeded_) {
            std::error_code error;
            std::filesystem::remove_all(root_, error);
        }
    }

    const std::filesystem::path& root() const noexcept { return root_; }
    void MarkSucceeded() noexcept { succeeded_ = true; }

    TestArtifact(const TestArtifact&) = delete;
    TestArtifact& operator=(const TestArtifact&) = delete;

private:
    std::filesystem::path root_;
    bool succeeded_ = false;
};

struct TimedObservation {
    std::uint64_t timestamp_100ns = 0U;
    bool marker_active = false;
};

std::vector<std::uint64_t> BuildMarkerSchedule(std::uint32_t duration_seconds) {
    std::vector<std::uint64_t> markers;
    // The release fixture cadence is exactly one flash/beep every 30 seconds.
    // Keep the eight-second CTest smoke useful by using a denser cadence only
    // below the first full 30-second interval.
    const std::uint32_t interval_seconds = duration_seconds >= 60U ? 30U : 2U;
    for (std::uint32_t second = 1U; second + 1U < duration_seconds; second += interval_seconds) {
        markers.push_back(static_cast<std::uint64_t>(second) * kHundredNanosecondsPerSecond);
    }
    Expect(!markers.empty(), "The A/V marker schedule unexpectedly contains no marker.");
    return markers;
}

bool IsMarkerActiveAt(std::uint64_t timestamp_100ns,
                      const std::vector<std::uint64_t>& marker_timestamps,
                      std::uint64_t marker_duration_100ns) {
    const auto next = std::upper_bound(marker_timestamps.begin(), marker_timestamps.end(), timestamp_100ns);
    if (next == marker_timestamps.begin()) {
        return false;
    }
    const std::uint64_t marker = *std::prev(next);
    return timestamp_100ns >= marker && timestamp_100ns - marker < marker_duration_100ns;
}

std::uint64_t VideoTimestampForFrame(std::uint64_t frame_index) {
    return frame_index * kHundredNanosecondsPerSecond / kFrameRate;
}

std::uint64_t VideoDurationForFrame(std::uint64_t frame_index) {
    return VideoTimestampForFrame(frame_index + 1U) - VideoTimestampForFrame(frame_index);
}

std::uint64_t AudioTimestampForBlock(std::uint64_t block_index) {
    const std::uint64_t frames = block_index * kAudioWriteFrames;
    return frames * kHundredNanosecondsPerSecond / kSampleRate;
}

void FillAudioBlock(std::vector<float>* samples,
                    std::uint64_t first_frame,
                    const std::vector<std::uint64_t>& marker_timestamps) {
    Expect(samples != nullptr && samples->size() == static_cast<std::size_t>(kAudioWriteFrames) * kChannels,
           "Unexpected A/V marker audio block geometry.");
    std::fill(samples->begin(), samples->end(), 0.0F);

    const std::uint64_t block_end_frame = first_frame + kAudioWriteFrames;
    const std::uint64_t first_timestamp = first_frame * kHundredNanosecondsPerSecond / kSampleRate;
    const std::uint64_t last_timestamp = block_end_frame * kHundredNanosecondsPerSecond / kSampleRate;
    const auto next = std::upper_bound(marker_timestamps.begin(), marker_timestamps.end(), first_timestamp);
    auto marker = next == marker_timestamps.begin() ? next : std::prev(next);

    for (; marker != marker_timestamps.end(); ++marker) {
        const std::uint64_t marker_end = *marker + kBeepDuration100ns;
        if (*marker >= last_timestamp) {
            break;
        }
        if (marker_end <= first_timestamp) {
            continue;
        }
        const std::uint64_t marker_first_frame = *marker * kSampleRate / kHundredNanosecondsPerSecond;
        const std::uint64_t marker_end_frame = marker_end * kSampleRate / kHundredNanosecondsPerSecond;
        const std::uint64_t overlap_start = (std::max)(first_frame, marker_first_frame);
        const std::uint64_t overlap_end = (std::min)(block_end_frame, marker_end_frame);
        for (std::uint64_t frame = overlap_start; frame < overlap_end; ++frame) {
            const double phase = 2.0 * kPi * kBeepFrequencyHz *
                                 static_cast<double>(frame - marker_first_frame) /
                                 static_cast<double>(kSampleRate);
            const float value = static_cast<float>(kBeepAmplitude * std::sin(phase));
            const std::size_t offset = static_cast<std::size_t>(frame - first_frame) * kChannels;
            (*samples)[offset] = value;
            (*samples)[offset + 1U] = value;
        }
    }
}

void FillVideoFrame(std::vector<std::uint8_t>* bytes, bool marker_active) {
    const std::size_t luma_bytes = static_cast<std::size_t>(kWidth) * kHeight;
    const std::size_t total_bytes = luma_bytes * 3U / 2U;
    Expect(bytes != nullptr && bytes->size() == total_bytes, "Unexpected A/V marker video frame geometry.");
    std::fill(bytes->begin(), bytes->begin() + static_cast<std::ptrdiff_t>(luma_bytes),
              marker_active ? static_cast<std::uint8_t>(235U) : static_cast<std::uint8_t>(16U));
    std::fill(bytes->begin() + static_cast<std::ptrdiff_t>(luma_bytes), bytes->end(),
              static_cast<std::uint8_t>(128U));
}

void WriteMarkerMp4(const std::filesystem::path& output,
                    std::uint32_t duration_seconds,
                    const std::vector<std::uint64_t>& marker_timestamps) {
    recorder::mp4::Error create_error = recorder::mp4::Error::InvalidArgument;
    std::string detail;
    auto writer = recorder::mp4::Writer::Create(
        {output, kWidth, kHeight, 1'500'000U, 128'000U, kFrameRate}, &create_error, &detail);
    if (writer == nullptr || create_error != recorder::mp4::Error::Ok) {
        Fail("Could not create the H.264/AAC marker MP4: " + detail);
    }

    const std::uint64_t audio_blocks =
        static_cast<std::uint64_t>(duration_seconds) * kSampleRate / kAudioWriteFrames;
    const std::uint64_t video_frames = static_cast<std::uint64_t>(duration_seconds) * kFrameRate;
    std::vector<float> audio(static_cast<std::size_t>(kAudioWriteFrames) * kChannels);
    std::vector<std::uint8_t> video(static_cast<std::size_t>(kWidth) * kHeight * 3U / 2U);
    std::uint64_t next_audio_block = 0U;
    std::uint64_t next_video_frame = 0U;

    while (next_audio_block < audio_blocks || next_video_frame < video_frames) {
        const std::uint64_t audio_timestamp = next_audio_block < audio_blocks
            ? AudioTimestampForBlock(next_audio_block) : (std::numeric_limits<std::uint64_t>::max)();
        const std::uint64_t video_timestamp = next_video_frame < video_frames
            ? VideoTimestampForFrame(next_video_frame) : (std::numeric_limits<std::uint64_t>::max)();
        if (video_timestamp <= audio_timestamp) {
            const bool marker_active = IsMarkerActiveAt(video_timestamp, marker_timestamps, kFlashDuration100ns);
            FillVideoFrame(&video, marker_active);
            const recorder::mp4::Error result = writer->WriteVideoNv12(
                video.data(), kWidth, video_timestamp, VideoDurationForFrame(next_video_frame), &detail);
            if (result != recorder::mp4::Error::Ok) {
                Fail("Could not write a marker video frame: " + detail);
            }
            ++next_video_frame;
        } else {
            const std::uint64_t first_frame = next_audio_block * kAudioWriteFrames;
            FillAudioBlock(&audio, first_frame, marker_timestamps);
            const recorder::mp4::Error result = writer->WriteAudioFrames(
                audio.data(), kAudioWriteFrames, audio_timestamp, &detail);
            if (result != recorder::mp4::Error::Ok) {
                Fail("Could not write a marker audio block: " + detail);
            }
            ++next_audio_block;
        }
    }

    if (writer->Finalize(&detail) != recorder::mp4::Error::Ok) {
        Fail("Could not finalize the H.264/AAC marker MP4: " + detail);
    }
    writer.reset();
    std::error_code error;
    if (!std::filesystem::is_regular_file(output, error) || error ||
        std::filesystem::file_size(output, error) == 0U || error) {
        Fail("The H.264/AAC marker MP4 was not published.");
    }
}

ComPtr<IMFSourceReader> OpenReader(const std::filesystem::path& path) {
    ComPtr<IMFSourceReader> reader;
    ExpectHr(MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader), "Could not reopen the marker MP4.");
    Expect(reader != nullptr, "Media Foundation returned an empty source reader.");
    return reader;
}

void ExpectNativeStreamType(IMFSourceReader* reader,
                            DWORD stream,
                            const GUID& expected_major,
                            const GUID& expected_subtype,
                            const char* error_message) {
    ComPtr<IMFMediaType> type;
    GUID major{};
    GUID subtype{};
    ExpectHr(reader->GetNativeMediaType(stream, 0U, &type), error_message);
    Expect(type != nullptr &&
           SUCCEEDED(type->GetGUID(MF_MT_MAJOR_TYPE, &major)) && major == expected_major &&
           SUCCEEDED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) && subtype == expected_subtype,
           error_message);
}

void ConfigureVideoDecoder(IMFSourceReader* reader) {
    ComPtr<IMFMediaType> decoded;
    ExpectHr(MFCreateMediaType(&decoded), "Could not allocate the video decoder media type.");
    ExpectHr(decoded->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video), "Could not set the video decoder major type.");
    ExpectHr(decoded->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12), "Could not request NV12 video decoding.");
    ExpectHr(reader->SetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr, decoded.Get()),
             "The H.264 stream could not be configured for NV12 decoding.");
}

void ConfigureAudioDecoder(IMFSourceReader* reader) {
    ComPtr<IMFMediaType> decoded;
    ExpectHr(MFCreateMediaType(&decoded), "Could not allocate the audio decoder media type.");
    ExpectHr(decoded->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio), "Could not set the audio decoder major type.");
    ExpectHr(decoded->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM), "Could not request PCM audio decoding.");
    ExpectHr(decoded->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kChannels), "Could not configure decoded audio channels.");
    ExpectHr(decoded->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kSampleRate), "Could not configure decoded audio rate.");
    ExpectHr(decoded->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16U), "Could not configure decoded audio bit depth.");
    ExpectHr(decoded->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4U), "Could not configure decoded audio block alignment.");
    ExpectHr(decoded->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192'000U),
             "Could not configure decoded audio byte rate.");
    ExpectHr(reader->SetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr, decoded.Get()),
             "The AAC stream could not be configured for PCM decoding.");
}

bool ReadNextDecodedSample(IMFSourceReader* reader,
                           DWORD stream,
                           std::uint64_t* timestamp_100ns,
                           ComPtr<IMFSample>* sample_out) {
    Expect(timestamp_100ns != nullptr && sample_out != nullptr, "Invalid decoded sample output parameter.");
    sample_out->Reset();
    for (std::uint32_t attempt = 0U; attempt < kMaximumReadAttempts; ++attempt) {
        DWORD flags = 0U;
        LONGLONG sample_time = 0;
        ComPtr<IMFSample> sample;
        // The FIRST_* source-reader selectors are accepted input sentinels;
        // their returned stream index is implementation-specific, so no
        // equality assertion belongs here.
        ExpectHr(reader->ReadSample(stream, 0U, nullptr, &flags, &sample_time, &sample),
                 "Media Foundation failed while decoding the marker MP4.");
        if ((flags & MF_SOURCE_READERF_ERROR) != 0U) {
            Fail("Media Foundation reported a decode error in the marker MP4.");
        }
        if (sample != nullptr) {
            Expect(sample_time >= 0, "Source reader returned a negative presentation timestamp.");
            *timestamp_100ns = static_cast<std::uint64_t>(sample_time);
            sample_out->Attach(sample.Detach());
            return true;
        }
        if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0U) {
            return false;
        }
    }
    Fail("Source reader did not return a decoded sample within the bounded retry limit.");
}

double AverageLuma(const ComPtr<IMFSample>& sample) {
    ComPtr<IMFMediaBuffer> buffer;
    ExpectHr(sample->ConvertToContiguousBuffer(&buffer), "Could not flatten an NV12 decoded video frame.");
    Expect(buffer != nullptr, "Decoded video frame has no media buffer.");

    BYTE* data = nullptr;
    DWORD maximum = 0U;
    DWORD current = 0U;
    ExpectHr(buffer->Lock(&data, &maximum, &current), "Could not lock an NV12 decoded video frame.");
    if (data == nullptr || current < static_cast<DWORD>(kWidth) * kHeight) {
        const HRESULT unlock = buffer->Unlock();
        (void)unlock;
        Fail("Decoded NV12 frame is smaller than its luma plane.");
    }

    std::uint64_t luma_sum = 0U;
    constexpr std::uint32_t kProbeRows = 9U;
    constexpr std::uint32_t kProbeColumns = 11U;
    for (std::uint32_t row = 0U; row < kProbeRows; ++row) {
        const std::uint32_t y = row * (kHeight - 1U) / (kProbeRows - 1U);
        for (std::uint32_t column = 0U; column < kProbeColumns; ++column) {
            const std::uint32_t x = column * (kWidth - 1U) / (kProbeColumns - 1U);
            luma_sum += data[static_cast<std::size_t>(y) * kWidth + x];
        }
    }
    const HRESULT unlock = buffer->Unlock();
    ExpectHr(unlock, "Could not unlock an NV12 decoded video frame.");
    return static_cast<double>(luma_sum) / static_cast<double>(kProbeRows * kProbeColumns);
}

double AveragePcmMagnitude(const ComPtr<IMFSample>& sample) {
    ComPtr<IMFMediaBuffer> buffer;
    ExpectHr(sample->ConvertToContiguousBuffer(&buffer), "Could not flatten a PCM decoded audio sample.");
    Expect(buffer != nullptr, "Decoded audio sample has no media buffer.");

    BYTE* data = nullptr;
    DWORD maximum = 0U;
    DWORD current = 0U;
    ExpectHr(buffer->Lock(&data, &maximum, &current), "Could not lock a PCM decoded audio sample.");
    if (data == nullptr || current < sizeof(std::int16_t) || current % sizeof(std::int16_t) != 0U) {
        const HRESULT unlock = buffer->Unlock();
        (void)unlock;
        Fail("Decoded PCM sample does not contain 16-bit samples.");
    }

    const std::size_t count = current / sizeof(std::int16_t);
    std::uint64_t magnitude_sum = 0U;
    for (std::size_t index = 0U; index < count; ++index) {
        std::int16_t value = 0;
        std::memcpy(&value, data + index * sizeof(value), sizeof(value));
        const std::uint32_t magnitude = value == (std::numeric_limits<std::int16_t>::min)()
            ? 32'768U
            : static_cast<std::uint32_t>(value < 0 ? -value : value);
        magnitude_sum += magnitude;
    }
    const HRESULT unlock = buffer->Unlock();
    ExpectHr(unlock, "Could not unlock a PCM decoded audio sample.");
    return static_cast<double>(magnitude_sum) / static_cast<double>(count);
}

std::vector<TimedObservation> DecodeVideoObservations(const std::filesystem::path& output) {
    ComPtr<IMFSourceReader> reader = OpenReader(output);
    ExpectNativeStreamType(reader.Get(), static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
                           MFMediaType_Video, MFVideoFormat_H264,
                           "The reopened MP4 is missing an H.264 video stream.");
    ExpectNativeStreamType(reader.Get(), static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
                           MFMediaType_Audio, MFAudioFormat_AAC,
                           "The reopened MP4 is missing an AAC audio stream.");
    ConfigureVideoDecoder(reader.Get());

    std::vector<TimedObservation> observations;
    bool have_previous_timestamp = false;
    std::uint64_t previous_timestamp = 0U;
    while (true) {
        std::uint64_t timestamp = 0U;
        ComPtr<IMFSample> sample;
        if (!ReadNextDecodedSample(reader.Get(), static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
                                   &timestamp, &sample)) {
            break;
        }
        if (have_previous_timestamp && timestamp < previous_timestamp) {
            Fail("Decoded H.264 presentation timestamps are not monotonic.");
        }
        observations.push_back({timestamp, AverageLuma(sample) >= kFlashAverageLumaThreshold});
        previous_timestamp = timestamp;
        have_previous_timestamp = true;
    }
    Expect(!observations.empty(), "The reopened H.264 stream decoded no video sample.");
    return observations;
}

std::vector<TimedObservation> DecodeAudioObservations(const std::filesystem::path& output) {
    ComPtr<IMFSourceReader> reader = OpenReader(output);
    ExpectNativeStreamType(reader.Get(), static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
                           MFMediaType_Audio, MFAudioFormat_AAC,
                           "The reopened MP4 is missing an AAC audio stream.");
    ConfigureAudioDecoder(reader.Get());

    std::vector<TimedObservation> observations;
    bool have_previous_timestamp = false;
    std::uint64_t previous_timestamp = 0U;
    while (true) {
        std::uint64_t timestamp = 0U;
        ComPtr<IMFSample> sample;
        if (!ReadNextDecodedSample(reader.Get(), static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
                                   &timestamp, &sample)) {
            break;
        }
        if (have_previous_timestamp && timestamp < previous_timestamp) {
            Fail("Decoded AAC presentation timestamps are not monotonic.");
        }
        observations.push_back({timestamp, AveragePcmMagnitude(sample) >= kBeepMeanMagnitudeThreshold});
        previous_timestamp = timestamp;
        have_previous_timestamp = true;
    }
    Expect(!observations.empty(), "The reopened AAC stream decoded no audio sample.");
    return observations;
}

std::vector<std::uint64_t> ExtractMarkerOnsets(const std::vector<TimedObservation>& observations) {
    std::vector<std::uint64_t> onsets;
    bool previous_active = false;
    for (const TimedObservation& observation : observations) {
        if (observation.marker_active && !previous_active) {
            onsets.push_back(observation.timestamp_100ns);
        }
        previous_active = observation.marker_active;
    }
    return onsets;
}

std::uint64_t MatchMarker(const std::vector<std::uint64_t>& candidates,
                          std::uint64_t expected,
                          const char* stream_name) {
    if (candidates.empty()) {
        Fail(std::string("No ") + stream_name + " marker was decoded.");
    }
    std::uint64_t best = candidates.front();
    std::uint64_t best_distance = TimestampDistance(best, expected);
    for (const std::uint64_t candidate : candidates) {
        const std::uint64_t distance = TimestampDistance(candidate, expected);
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    if (best_distance > kMarkerAssociationWindow100ns) {
        Fail(std::string("No ") + stream_name + " marker is close to expected timestamp " +
             FormatTimestamp(expected) + ".");
    }
    return best;
}

void VerifyMarkerTiming(const std::vector<std::uint64_t>& expected_markers,
                        const std::vector<TimedObservation>& video_observations,
                        const std::vector<TimedObservation>& audio_observations) {
    const std::vector<std::uint64_t> video_onsets = ExtractMarkerOnsets(video_observations);
    const std::vector<std::uint64_t> audio_onsets = ExtractMarkerOnsets(audio_observations);
    for (const std::uint64_t expected : expected_markers) {
        const std::uint64_t video = MatchMarker(video_onsets, expected, "video flash");
        const std::uint64_t audio = MatchMarker(audio_onsets, expected, "audio beep");
        if (TimestampDistance(video, expected) > kMaximumAvMarkerOffset100ns) {
            Fail("Video flash marker drifted beyond 80 ms from its canonical timestamp.");
        }
        if (TimestampDistance(audio, expected) > kMaximumAvMarkerOffset100ns) {
            Fail("Audio beep marker drifted beyond 80 ms from its canonical timestamp.");
        }
        if (TimestampDistance(video, audio) > kMaximumAvMarkerOffset100ns) {
            Fail("A/V marker offset exceeds the 80 ms acceptance limit.");
        }
    }
}

void VerifyStreamDurationDifference(const std::vector<TimedObservation>& video,
                                    const std::vector<TimedObservation>& audio) {
    Expect(!video.empty() && !audio.empty(), "Cannot compare empty A/V stream durations.");
    if (TimestampDistance(video.back().timestamp_100ns, audio.back().timestamp_100ns) >
        kHundredNanosecondsPerSecond) {
        Fail("Decoded H.264/AAC stream duration difference exceeds one second.");
    }
}

void SeekTo(IMFSourceReader* reader, std::uint64_t timestamp_100ns) {
    PROPVARIANT position{};
    position.vt = VT_I8;
    position.hVal.QuadPart = static_cast<LONGLONG>(timestamp_100ns);
    ExpectHr(reader->SetCurrentPosition(GUID_NULL, position), "Could not seek the reopened marker MP4.");
}

void VerifyVideoSeek(const std::filesystem::path& output, std::uint64_t marker_timestamp) {
    ComPtr<IMFSourceReader> reader = OpenReader(output);
    ConfigureVideoDecoder(reader.Get());
    SeekTo(reader.Get(), marker_timestamp > kSeekLead100ns ? marker_timestamp - kSeekLead100ns : 0U);

    bool found_flash = false;
    for (std::uint32_t attempt = 0U; attempt < kFrameRate * 4U; ++attempt) {
        std::uint64_t timestamp = 0U;
        ComPtr<IMFSample> sample;
        if (!ReadNextDecodedSample(reader.Get(), static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
                                   &timestamp, &sample)) {
            break;
        }
        if (timestamp > marker_timestamp + kSeekSearchWindow100ns) {
            break;
        }
        if (timestamp + kMaximumAvMarkerOffset100ns >= marker_timestamp &&
            AverageLuma(sample) >= kFlashAverageLumaThreshold) {
            found_flash = true;
            break;
        }
    }
    Expect(found_flash, "Seeking the reopened MP4 did not return the expected video flash marker.");
}

void VerifyAudioSeek(const std::filesystem::path& output, std::uint64_t marker_timestamp) {
    ComPtr<IMFSourceReader> reader = OpenReader(output);
    ConfigureAudioDecoder(reader.Get());
    SeekTo(reader.Get(), marker_timestamp > kSeekLead100ns ? marker_timestamp - kSeekLead100ns : 0U);

    bool found_beep = false;
    for (std::uint32_t attempt = 0U; attempt < 256U; ++attempt) {
        std::uint64_t timestamp = 0U;
        ComPtr<IMFSample> sample;
        if (!ReadNextDecodedSample(reader.Get(), static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
                                   &timestamp, &sample)) {
            break;
        }
        if (timestamp > marker_timestamp + kSeekSearchWindow100ns) {
            break;
        }
        if (timestamp + kMaximumAvMarkerOffset100ns >= marker_timestamp &&
            AveragePcmMagnitude(sample) >= kBeepMeanMagnitudeThreshold) {
            found_beep = true;
            break;
        }
    }
    Expect(found_beep, "Seeking the reopened MP4 did not return the expected audio beep marker.");
}

std::uint32_t ParseDuration(int argc, char* argv[]) {
    std::uint32_t duration = kDefaultDurationSeconds;
    for (int index = 1; index < argc; ++index) {
        const std::string_view argument(argv[index]);
        std::string_view value;
        if (argument == "--duration-seconds") {
            if (++index >= argc) {
                Fail("--duration-seconds requires an integer value.");
            }
            value = argv[index];
        } else if (argument.rfind("--duration-seconds=", 0U) == 0U) {
            value = argument.substr(std::string_view("--duration-seconds=").size());
        } else {
            Fail("Unknown argument. Use --duration-seconds <4..3600>.");
        }
        if (value.empty()) {
            Fail("--duration-seconds requires an integer value.");
        }
        std::uint64_t parsed = 0U;
        for (const char character : value) {
            if (character < '0' || character > '9') {
                Fail("--duration-seconds must be an unsigned decimal integer.");
            }
            parsed = parsed * 10U + static_cast<std::uint64_t>(character - '0');
            if (parsed > kMaximumDurationSeconds) {
                Fail("--duration-seconds exceeds the one-hour safety limit.");
            }
        }
        duration = static_cast<std::uint32_t>(parsed);
    }
    if (duration < kMinimumDurationSeconds || duration > kMaximumDurationSeconds) {
        Fail("--duration-seconds must be between 4 and 3600.");
    }
    return duration;
}

void Run(std::uint32_t duration_seconds) {
    const std::vector<std::uint64_t> markers = BuildMarkerSchedule(duration_seconds);
    TestArtifact artifact;
    const std::filesystem::path output = artifact.root() / "av-marker-acceptance.mp4";
    WriteMarkerMp4(output, duration_seconds, markers);

    const std::vector<TimedObservation> video = DecodeVideoObservations(output);
    const std::vector<TimedObservation> audio = DecodeAudioObservations(output);
    VerifyMarkerTiming(markers, video, audio);
    VerifyStreamDurationDifference(video, audio);

    const std::uint64_t seek_marker = markers[markers.size() / 2U];
    VerifyVideoSeek(output, seek_marker);
    VerifyAudioSeek(output, seek_marker);
    artifact.MarkSucceeded();
}

}  // namespace

int main(int argc, char* argv[]) {
    try {
        const std::uint32_t duration_seconds = ParseDuration(argc, argv);
        MediaFoundationRuntime runtime;
        Run(duration_seconds);
        std::cout << "PASS deterministic H.264/AAC A/V marker acceptance ("
                  << duration_seconds << " seconds, <=80 ms)\n";
        return 0;
    } catch (const std::exception& exception) {
        std::cerr << "FAIL deterministic H.264/AAC A/V marker acceptance: "
                  << exception.what() << '\n';
        return 1;
    }
}
