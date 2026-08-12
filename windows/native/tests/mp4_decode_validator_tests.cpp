#include "m4a_writer.h"
#include "mp4_decode_validator.h"
#include "mp4_mux_writer.h"

#include <mfapi.h>
#include <windows.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr std::uint32_t kWidth = 160U;
constexpr std::uint32_t kHeight = 90U;
constexpr std::uint32_t kAudioWriteFrames = 960U;
constexpr std::uint32_t kAudioBlocksPerFragment = 100U;
constexpr std::uint32_t kVideoFramesPerFragment = 60U;
constexpr std::uint64_t kAudioBlockDuration100ns = 200'000U;
constexpr std::uint64_t kVideoFrameDuration100ns = 333'333U;

void Expect(bool condition, const char* message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

class MediaFoundationRuntime final {
public:
    MediaFoundationRuntime() {
        const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(com) && com != RPC_E_CHANGED_MODE) {
            throw std::runtime_error("could not initialize COM for decode-validator tests");
        }
        owns_com_ = SUCCEEDED(com);

        const HRESULT mf = MFStartup(MF_VERSION, MFSTARTUP_FULL);
        if (FAILED(mf)) {
            if (owns_com_) {
                CoUninitialize();
            }
            throw std::runtime_error("could not start Media Foundation for decode-validator tests");
        }
        started_ = true;
    }

    ~MediaFoundationRuntime() {
        if (started_) {
            MFShutdown();
        }
        if (owns_com_) {
            CoUninitialize();
        }
    }

    MediaFoundationRuntime(const MediaFoundationRuntime&) = delete;
    MediaFoundationRuntime& operator=(const MediaFoundationRuntime&) = delete;

private:
    bool owns_com_ = false;
    bool started_ = false;
};

struct Box {
    std::size_t offset = 0U;
    std::size_t size = 0U;
    std::size_t header_size = 0U;
    std::array<unsigned char, 4U> type{};
};

std::uint32_t ReadBigEndian32(const std::vector<unsigned char>& bytes,
                              std::size_t offset) {
    Expect(offset <= bytes.size() && bytes.size() - offset >= 4U,
           "ISO-BMFF 32-bit field is outside the test artifact");
    return (static_cast<std::uint32_t>(bytes[offset]) << 24U) |
           (static_cast<std::uint32_t>(bytes[offset + 1U]) << 16U) |
           (static_cast<std::uint32_t>(bytes[offset + 2U]) << 8U) |
           static_cast<std::uint32_t>(bytes[offset + 3U]);
}

std::uint64_t ReadBigEndian64(const std::vector<unsigned char>& bytes,
                              std::size_t offset) {
    Expect(offset <= bytes.size() && bytes.size() - offset >= 8U,
           "ISO-BMFF 64-bit field is outside the test artifact");
    std::uint64_t value = 0U;
    for (std::size_t index = 0U; index < 8U; ++index) {
        value = (value << 8U) | bytes[offset + index];
    }
    return value;
}

bool HasType(const Box& box, const char type[5]) {
    return box.type[0U] == static_cast<unsigned char>(type[0]) &&
           box.type[1U] == static_cast<unsigned char>(type[1]) &&
           box.type[2U] == static_cast<unsigned char>(type[2]) &&
           box.type[3U] == static_cast<unsigned char>(type[3]);
}

bool TryReadBox(const std::vector<unsigned char>& bytes,
                std::size_t offset,
                std::size_t limit,
                Box* box) {
    if (box == nullptr || offset > limit || limit - offset < 8U ||
        limit > bytes.size()) {
        return false;
    }

    const std::uint32_t small_size = ReadBigEndian32(bytes, offset);
    std::size_t header_size = 8U;
    std::uint64_t declared_size = small_size;
    if (small_size == 1U) {
        if (limit - offset < 16U) {
            return false;
        }
        header_size = 16U;
        declared_size = ReadBigEndian64(bytes, offset + 8U);
    } else if (small_size == 0U) {
        // A zero-sized box runs to its enclosing box's end. It is valid in
        // general ISO-BMFF, but the recorder never writes it; accepting it
        // here would make a targeted late-fragment mutation ambiguous.
        return false;
    }

    if (declared_size < header_size ||
        declared_size > static_cast<std::uint64_t>(limit - offset) ||
        declared_size > (std::numeric_limits<std::size_t>::max)()) {
        return false;
    }

    box->offset = offset;
    box->size = static_cast<std::size_t>(declared_size);
    box->header_size = header_size;
    std::copy_n(bytes.begin() + static_cast<std::ptrdiff_t>(offset + 4U),
                4U, box->type.begin());
    return true;
}

std::vector<Box> ChildBoxes(const std::vector<unsigned char>& bytes,
                            const Box& parent) {
    std::vector<Box> children;
    const std::size_t payload_start = parent.offset + parent.header_size;
    const std::size_t payload_end = parent.offset + parent.size;
    std::size_t offset = payload_start;
    while (offset < payload_end) {
        Box child;
        Expect(TryReadBox(bytes, offset, payload_end, &child),
               "could not parse an ISO-BMFF child box in the test artifact");
        children.push_back(child);
        offset += child.size;
    }
    return children;
}

std::vector<unsigned char> ReadBytes(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    Expect(input.good(), "could not open decode-validator test artifact");
    return {std::istreambuf_iterator<char>(input), {}};
}

void WriteBytes(const std::filesystem::path& path,
                const std::vector<unsigned char>& bytes) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    Expect(output.good(), "could not overwrite corrupted decode-validator test artifact");
    output.write(reinterpret_cast<const char*>(bytes.data()),
                 static_cast<std::streamsize>(bytes.size()));
    Expect(output.good(), "could not write corrupted decode-validator test artifact");
}

// Retains the early fMP4 fragments byte-for-byte but corrupts a later trun's
// first sample size.  It is more meaningful than truncation: every top-level
// box remains structurally complete, so publication has to reject it by
// consuming the affected stream rather than by seeing a short file upfront.
void CorruptLaterFragment(const std::filesystem::path& path) {
    std::vector<unsigned char> bytes = ReadBytes(path);
    std::vector<Box> moofs;
    std::size_t offset = 0U;
    while (offset < bytes.size()) {
        Box top_level;
        Expect(TryReadBox(bytes, offset, bytes.size(), &top_level),
               "could not parse a top-level ISO-BMFF box in the test artifact");
        if (HasType(top_level, "moof")) {
            moofs.push_back(top_level);
        }
        offset += top_level.size;
    }
    Expect(moofs.size() >= 3U,
           "test recording did not produce an early and a later fMP4 fragment");

    // Select the second fragment so a fully valid first fragment remains in
    // front of the deliberately malformed later one.
    const Box& later_moof = moofs[1U];
    for (const Box& child : ChildBoxes(bytes, later_moof)) {
        if (!HasType(child, "traf")) {
            continue;
        }
        for (const Box& traf_child : ChildBoxes(bytes, child)) {
            if (!HasType(traf_child, "trun")) {
                continue;
            }
            const std::size_t full_box_offset =
                traf_child.offset + traf_child.header_size;
            const std::size_t sample_count_offset = full_box_offset + 4U;
            Expect(sample_count_offset <= bytes.size() &&
                       bytes.size() - sample_count_offset >= 4U,
                   "later trun has no sample-count field");
            Expect(ReadBigEndian32(bytes, sample_count_offset) > 0U,
                   "later trun unexpectedly has no samples");
            const std::uint32_t flags =
                (static_cast<std::uint32_t>(bytes[full_box_offset + 1U]) << 16U) |
                (static_cast<std::uint32_t>(bytes[full_box_offset + 2U]) << 8U) |
                static_cast<std::uint32_t>(bytes[full_box_offset + 3U]);
            std::size_t entry_offset = sample_count_offset + 4U;
            if ((flags & 0x000001U) != 0U) entry_offset += 4U;  // data_offset
            if ((flags & 0x000004U) != 0U) entry_offset += 4U;  // first_sample_flags
            if ((flags & 0x000100U) != 0U) entry_offset += 4U;  // sample_duration
            if ((flags & 0x000200U) == 0U ||
                entry_offset > traf_child.offset + traf_child.size ||
                traf_child.offset + traf_child.size - entry_offset < 4U) {
                continue;
            }

            // Inflate only a later encoded access unit, which causes its
            // decoder/parser to consume invalid data after the valid early
            // fragment.  A complete-to-EOS publication gate must reject it.
            bytes[entry_offset] = 0x00U;
            bytes[entry_offset + 1U] = 0xffU;
            bytes[entry_offset + 2U] = 0xffU;
            bytes[entry_offset + 3U] = 0xffU;
            WriteBytes(path, bytes);
            return;
        }
    }
    throw std::runtime_error("later fMP4 fragment does not contain a trun box");
}

void WriteAudioSafetyRecording(const std::filesystem::path& output) {
    recorder::m4a::Error error = recorder::m4a::Error::Ok;
    std::string detail;
    auto writer = recorder::m4a::Writer::CreateWorkFile(
        output, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == recorder::m4a::Error::Ok,
           "could not create audio-only decode-validator fixture");

    std::vector<float> samples(kAudioWriteFrames * 2U, 0.0F);
    for (std::uint32_t fragment = 0U; fragment < 3U; ++fragment) {
        for (std::uint32_t block = 0U; block < kAudioBlocksPerFragment; ++block) {
            samples[(static_cast<std::size_t>(block) * 37U) % samples.size()] =
                (block % 2U == 0U) ? 0.25F : -0.25F;
            const std::uint64_t timestamp =
                static_cast<std::uint64_t>(fragment * kAudioBlocksPerFragment + block) *
                kAudioBlockDuration100ns;
            Expect(writer->WriteFrames(samples.data(), kAudioWriteFrames,
                                       timestamp, &detail) == recorder::m4a::Error::Ok,
                   "could not write audio-only decode-validator fixture");
        }
        recorder::m4a::DurableCheckpoint checkpoint;
        const std::uint64_t checkpoint_time =
            static_cast<std::uint64_t>(fragment + 1U) *
            kAudioBlocksPerFragment * kAudioBlockDuration100ns;
        Expect(writer->CreateDurableCheckpoint(checkpoint_time, &checkpoint,
                                                &detail) == recorder::m4a::Error::Ok &&
                   checkpoint.file_size_bytes > 0U,
               "could not checkpoint audio-only decode-validator fixture");
    }
    Expect(writer->Finalize(&detail) == recorder::m4a::Error::Ok,
           "could not finalize audio-only decode-validator fixture");
    writer.reset();
}

void WriteAudioVideoRecording(const std::filesystem::path& output) {
    recorder::mp4::Error error = recorder::mp4::Error::Ok;
    std::string detail;
    auto writer = recorder::mp4::Writer::Create(
        {output, kWidth, kHeight, 1'000'000U, 128'000U, 30U}, &error,
        &detail);
    Expect(writer != nullptr && error == recorder::mp4::Error::Ok,
           "could not create A/V decode-validator fixture");

    std::vector<float> samples(kAudioWriteFrames * 2U, 0.0F);
    std::vector<std::uint8_t> video(
        kWidth * kHeight * 3U / 2U, static_cast<std::uint8_t>(16U));
    std::fill(video.begin() + kWidth * kHeight, video.end(),
              static_cast<std::uint8_t>(128U));

    for (std::uint32_t fragment = 0U; fragment < 3U; ++fragment) {
        std::uint32_t audio_block = 0U;
        std::uint32_t video_frame = 0U;
        while (audio_block < kAudioBlocksPerFragment ||
               video_frame < kVideoFramesPerFragment) {
            const std::uint64_t audio_timestamp = audio_block < kAudioBlocksPerFragment
                ? static_cast<std::uint64_t>(
                      fragment * kAudioBlocksPerFragment + audio_block) *
                    kAudioBlockDuration100ns
                : (std::numeric_limits<std::uint64_t>::max)();
            const std::uint64_t video_timestamp = video_frame < kVideoFramesPerFragment
                ? static_cast<std::uint64_t>(
                      fragment * kVideoFramesPerFragment + video_frame) *
                    kVideoFrameDuration100ns
                : (std::numeric_limits<std::uint64_t>::max)();
            if (video_timestamp <= audio_timestamp) {
                const std::uint32_t index =
                    fragment * kVideoFramesPerFragment + video_frame;
                video[index % (kWidth * kHeight)] =
                    static_cast<std::uint8_t>(16U + (index % 48U));
                Expect(writer->WriteVideoNv12(
                           video.data(), kWidth, video_timestamp,
                           kVideoFrameDuration100ns, &detail) == recorder::mp4::Error::Ok,
                       "could not write A/V video decode-validator fixture");
                ++video_frame;
            } else {
                samples[(static_cast<std::size_t>(audio_block) * 41U) % samples.size()] =
                    (audio_block % 2U == 0U) ? 0.20F : -0.20F;
                Expect(writer->WriteAudioFrames(samples.data(), kAudioWriteFrames,
                                                 audio_timestamp, &detail) == recorder::mp4::Error::Ok,
                       "could not write A/V audio decode-validator fixture");
                ++audio_block;
            }
        }
        recorder::mp4::DurableCheckpoint checkpoint;
        const std::uint64_t checkpoint_time =
            static_cast<std::uint64_t>(fragment + 1U) *
            kAudioBlocksPerFragment * kAudioBlockDuration100ns;
        Expect(writer->CreateDurableCheckpoint(checkpoint_time, &checkpoint,
                                                &detail) == recorder::mp4::Error::Ok &&
                   checkpoint.file_size_bytes > 0U,
               "could not checkpoint A/V decode-validator fixture");
    }
    Expect(writer->Finalize(&detail) == recorder::mp4::Error::Ok,
           "could not finalize A/V decode-validator fixture");
    writer.reset();
}

void AudioOnlyValidatorRejectsLaterCorruption(const std::filesystem::path& root) {
    const auto fixture = root / "audio-safety.mp4";
    WriteAudioSafetyRecording(fixture);

    recorder::mp4::validation::Report report;
    std::string detail;
    const recorder::mp4::validation::Error valid_result =
        recorder::mp4::validation::ProbeDecodableAacM4a(fixture, &report, &detail);
    // Three two-second fragments encode roughly 280 AAC access units. A
    // threshold far above the first fragment proves the production probe did
    // not stop after merely obtaining one early decoded sample.
    if (valid_result != recorder::mp4::validation::Error::Ok ||
        report.decoded_audio_samples < 200U) {
        throw std::runtime_error(
            "audio-only validator did not consume the valid fixture through EOS: " + detail);
    }

    CorruptLaterFragment(fixture);
    report = {};
    Expect(recorder::mp4::validation::ProbeDecodableAacM4a(
               fixture, &report, &detail) == recorder::mp4::validation::Error::AudioDecodeFailed,
           "audio-only validator accepted a corrupt later fMP4 fragment");
}

void AudioVideoValidatorRejectsLaterCorruption(const std::filesystem::path& root) {
    const auto fixture = root / "audio-video.mp4";
    WriteAudioVideoRecording(fixture);

    recorder::mp4::validation::Report report;
    std::string detail;
    const recorder::mp4::validation::Error valid_result =
        recorder::mp4::validation::ProbeDecodableH264AacMp4(fixture, &report, &detail);
    // The A/V fixture contains 180 video frames and roughly 280 AAC access
    // units across its late fragments. These bounds catch a first-sample-only
    // validator as well as an early-fragment-only traversal.
    if (valid_result != recorder::mp4::validation::Error::Ok ||
        report.decoded_video_samples < 120U || report.decoded_audio_samples < 200U) {
        throw std::runtime_error(
            "A/V validator did not consume the valid fixture through EOS: " + detail);
    }

    CorruptLaterFragment(fixture);
    report = {};
    const recorder::mp4::validation::Error result =
        recorder::mp4::validation::ProbeDecodableH264AacMp4(
            fixture, &report, &detail);
    Expect(result == recorder::mp4::validation::Error::VideoDecodeFailed ||
               result == recorder::mp4::validation::Error::AudioDecodeFailed,
           "A/V validator accepted a corrupt later fMP4 fragment");
}

}  // namespace

int main() {
    const auto root = std::filesystem::temp_directory_path() /
        ("teams-recorder-mp4-decode-validator-" +
         std::to_string(GetCurrentProcessId()));
    std::error_code cleanup_error;
    try {
        std::filesystem::remove_all(root, cleanup_error);
        cleanup_error.clear();
        std::filesystem::create_directories(root, cleanup_error);
        Expect(!cleanup_error, "could not create decode-validator test directory");

        MediaFoundationRuntime runtime;
        AudioOnlyValidatorRejectsLaterCorruption(root);
        AudioVideoValidatorRejectsLaterCorruption(root);

        std::filesystem::remove_all(root, cleanup_error);
        Expect(!cleanup_error, "could not remove decode-validator test directory");
        std::cout << "PASS MP4 decoder validates every required stream through EOS\n";
        return 0;
    } catch (const std::exception& exception) {
        std::filesystem::remove_all(root, cleanup_error);
        std::cerr << "FAIL MP4 decoder EOS validation: " << exception.what() << '\n';
        return 1;
    }
}
