#include "mp4_decode_validator.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <windows.h>
#include <wrl/client.h>

#include <array>
#include <filesystem>
#include <fstream>
#include <limits>
#include <vector>

namespace recorder::mp4::validation {
namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kVideoStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr DWORD kAudioStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
constexpr std::uint32_t kChannels = 2;
constexpr std::uint32_t kSampleRate = 48'000;
constexpr std::uint64_t kMaximumMoofPayloadBytes = 32ULL * 1024ULL * 1024ULL;
constexpr std::uint32_t kMaximumSamplesPerFragment = 1'000'000U;

constexpr std::uint32_t FourCc(char first, char second, char third,
                               char fourth) noexcept {
    return (static_cast<std::uint32_t>(static_cast<unsigned char>(first)) << 24U) |
           (static_cast<std::uint32_t>(static_cast<unsigned char>(second)) << 16U) |
           (static_cast<std::uint32_t>(static_cast<unsigned char>(third)) << 8U) |
           static_cast<std::uint32_t>(static_cast<unsigned char>(fourth));
}

constexpr std::uint32_t kBoxMoof = FourCc('m', 'o', 'o', 'f');
constexpr std::uint32_t kBoxMdat = FourCc('m', 'd', 'a', 't');
constexpr std::uint32_t kBoxTraf = FourCc('t', 'r', 'a', 'f');
constexpr std::uint32_t kBoxTfhd = FourCc('t', 'f', 'h', 'd');
constexpr std::uint32_t kBoxTrun = FourCc('t', 'r', 'u', 'n');

struct IsoBox {
    std::uint64_t offset = 0U;
    std::uint64_t size = 0U;
    std::uint64_t header_size = 0U;
    std::uint32_t type = 0U;
};

std::uint32_t ReadBigEndian32(const unsigned char* bytes) noexcept {
    return (static_cast<std::uint32_t>(bytes[0U]) << 24U) |
           (static_cast<std::uint32_t>(bytes[1U]) << 16U) |
           (static_cast<std::uint32_t>(bytes[2U]) << 8U) |
           static_cast<std::uint32_t>(bytes[3U]);
}

std::uint64_t ReadBigEndian64(const unsigned char* bytes) noexcept {
    std::uint64_t result = 0U;
    for (std::size_t index = 0U; index < 8U; ++index) {
        result = (result << 8U) | bytes[index];
    }
    return result;
}

bool ReadFileBoxHeader(std::ifstream* input,
                       std::uint64_t file_size,
                       std::uint64_t offset,
                       IsoBox* box) noexcept {
    if (input == nullptr || box == nullptr || offset > file_size ||
        file_size - offset < 8U ||
        offset > static_cast<std::uint64_t>((std::numeric_limits<std::streamoff>::max)())) {
        return false;
    }

    std::array<unsigned char, 16U> bytes{};
    input->clear();
    input->seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    input->read(reinterpret_cast<char*>(bytes.data()), 8U);
    if (!*input) {
        return false;
    }

    const std::uint32_t small_size = ReadBigEndian32(bytes.data());
    std::uint64_t header_size = 8U;
    std::uint64_t size = small_size;
    if (small_size == 1U) {
        if (file_size - offset < 16U) {
            return false;
        }
        input->read(reinterpret_cast<char*>(bytes.data() + 8U), 8U);
        if (!*input) {
            return false;
        }
        header_size = 16U;
        size = ReadBigEndian64(bytes.data() + 8U);
    } else if (small_size == 0U) {
        // ISO-BMFF permits a top-level zero size to mean "to EOF".  It
        // cannot conceal a later box because this scanner moves to EOF.
        size = file_size - offset;
    }

    if (size < header_size || size > file_size - offset) {
        return false;
    }
    *box = {offset, size, header_size, ReadBigEndian32(bytes.data() + 4U)};
    return true;
}

bool ReadMemoryBox(const std::vector<unsigned char>& bytes,
                   std::size_t offset,
                   std::size_t limit,
                   IsoBox* box) noexcept {
    if (box == nullptr || offset > limit || limit > bytes.size() ||
        limit - offset < 8U) {
        return false;
    }
    const auto* begin = bytes.data() + offset;
    const std::uint32_t small_size = ReadBigEndian32(begin);
    std::uint64_t header_size = 8U;
    std::uint64_t size = small_size;
    if (small_size == 1U) {
        if (limit - offset < 16U) {
            return false;
        }
        header_size = 16U;
        size = ReadBigEndian64(begin + 8U);
    } else if (small_size == 0U) {
        // A zero-sized child is needlessly ambiguous in a moof. The recorder
        // never writes one, so reject it rather than accepting a partial tail.
        return false;
    }
    if (size < header_size || size > static_cast<std::uint64_t>(limit - offset)) {
        return false;
    }
    *box = {static_cast<std::uint64_t>(offset), size, header_size,
            ReadBigEndian32(begin + 4U)};
    return true;
}

bool Advance(std::size_t* offset, std::size_t amount, std::size_t limit) noexcept {
    if (offset == nullptr || *offset > limit || amount > limit - *offset) {
        return false;
    }
    *offset += amount;
    return true;
}

bool RemainingBytesAreZero(const std::vector<unsigned char>& bytes,
                           std::size_t offset,
                           std::size_t limit) noexcept {
    if (offset > limit || limit > bytes.size()) return false;
    for (; offset < limit; ++offset) {
        if (bytes[offset] != 0U) return false;
    }
    return true;
}

bool AddBytes(std::uint64_t value, std::uint64_t* total) noexcept {
    if (total == nullptr || value == 0U ||
        *total > (std::numeric_limits<std::uint64_t>::max)() - value) {
        return false;
    }
    *total += value;
    return true;
}

bool ParseTfhdDefaultSampleSize(const std::vector<unsigned char>& bytes,
                                const IsoBox& tfhd,
                                bool* has_default_sample_size,
                                std::uint32_t* default_sample_size) noexcept {
    if (has_default_sample_size == nullptr || default_sample_size == nullptr ||
        tfhd.offset > bytes.size() || tfhd.size > bytes.size() - tfhd.offset ||
        tfhd.size < tfhd.header_size + 8U) {
        return false;
    }
    const std::size_t payload = static_cast<std::size_t>(tfhd.offset + tfhd.header_size);
    const std::size_t end = static_cast<std::size_t>(tfhd.offset + tfhd.size);
    const std::uint32_t flags = ReadBigEndian32(bytes.data() + payload) & 0x00ff'ffffU;
    std::size_t cursor = payload + 4U;
    if (!Advance(&cursor, 4U, end) ||
        ReadBigEndian32(bytes.data() + payload + 4U) == 0U) {
        return false;
    }
    if ((flags & 0x000001U) != 0U && !Advance(&cursor, 8U, end)) return false;
    if ((flags & 0x000002U) != 0U && !Advance(&cursor, 4U, end)) return false;
    if ((flags & 0x000008U) != 0U && !Advance(&cursor, 4U, end)) return false;

    *has_default_sample_size = (flags & 0x000010U) != 0U;
    *default_sample_size = 0U;
    if (*has_default_sample_size) {
        if (!Advance(&cursor, 4U, end)) return false;
        *default_sample_size = ReadBigEndian32(bytes.data() + cursor - 4U);
        if (*default_sample_size == 0U) return false;
    }
    if ((flags & 0x000020U) != 0U && !Advance(&cursor, 4U, end)) return false;
    // The Microsoft fMP4 sink currently leaves four zero reserved bytes in
    // tfhd.  Preserve strict bounds while accepting that documented writer
    // shape; non-zero unknown data remains an invalid recovery candidate.
    return RemainingBytesAreZero(bytes, cursor, end);
}

bool ParseTrunSampleBytes(const std::vector<unsigned char>& bytes,
                          const IsoBox& trun,
                          bool has_default_sample_size,
                          std::uint32_t default_sample_size,
                          std::uint64_t* sample_bytes) noexcept {
    if (sample_bytes == nullptr || trun.offset > bytes.size() ||
        trun.size > bytes.size() - trun.offset ||
        trun.size < trun.header_size + 8U) {
        return false;
    }
    const std::size_t payload = static_cast<std::size_t>(trun.offset + trun.header_size);
    const std::size_t end = static_cast<std::size_t>(trun.offset + trun.size);
    const std::uint32_t flags = ReadBigEndian32(bytes.data() + payload) & 0x00ff'ffffU;
    const std::uint32_t sample_count = ReadBigEndian32(bytes.data() + payload + 4U);
    if (sample_count == 0U || sample_count > kMaximumSamplesPerFragment) {
        return false;
    }

    std::size_t cursor = payload + 8U;
    if ((flags & 0x000001U) != 0U && !Advance(&cursor, 4U, end)) return false;
    if ((flags & 0x000004U) != 0U && !Advance(&cursor, 4U, end)) return false;
    const bool has_duration = (flags & 0x000100U) != 0U;
    const bool has_size = (flags & 0x000200U) != 0U;
    const bool has_sample_flags = (flags & 0x000400U) != 0U;
    const bool has_composition_offset = (flags & 0x000800U) != 0U;
    const std::size_t fields_per_sample =
        static_cast<std::size_t>(has_duration) + static_cast<std::size_t>(has_size) +
        static_cast<std::size_t>(has_sample_flags) +
        static_cast<std::size_t>(has_composition_offset);
    if (fields_per_sample > 0U &&
        sample_count > (end - cursor) / (fields_per_sample * 4U)) {
        return false;
    }
    if (!has_size && !has_default_sample_size) {
        return false;
    }

    std::uint64_t total = 0U;
    for (std::uint32_t sample = 0U; sample < sample_count; ++sample) {
        if (has_duration && !Advance(&cursor, 4U, end)) return false;
        std::uint32_t size = default_sample_size;
        if (has_size) {
            if (!Advance(&cursor, 4U, end)) return false;
            size = ReadBigEndian32(bytes.data() + cursor - 4U);
        }
        if (size == 0U || !AddBytes(size, &total)) return false;
        if (has_sample_flags && !Advance(&cursor, 4U, end)) return false;
        if (has_composition_offset && !Advance(&cursor, 4U, end)) return false;
    }
    if (cursor != end) {
        return false;
    }
    *sample_bytes = total;
    return true;
}

bool ParseTrafSampleBytes(const std::vector<unsigned char>& bytes,
                          const IsoBox& traf,
                          std::uint64_t* sample_bytes) noexcept {
    if (sample_bytes == nullptr || traf.offset > bytes.size() ||
        traf.size > bytes.size() - traf.offset) {
        return false;
    }
    const std::size_t begin = static_cast<std::size_t>(traf.offset + traf.header_size);
    const std::size_t end = static_cast<std::size_t>(traf.offset + traf.size);
    bool found_tfhd = false;
    bool has_default_sample_size = false;
    std::uint32_t default_sample_size = 0U;
    std::size_t offset = begin;
    while (offset < end) {
        IsoBox child;
        if (!ReadMemoryBox(bytes, offset, end, &child)) return false;
        if (child.type == kBoxTfhd) {
            if (found_tfhd || !ParseTfhdDefaultSampleSize(
                                  bytes, child, &has_default_sample_size,
                                  &default_sample_size)) {
                return false;
            }
            found_tfhd = true;
        }
        offset += static_cast<std::size_t>(child.size);
    }
    if (!found_tfhd) return false;

    bool found_trun = false;
    std::uint64_t total = 0U;
    offset = begin;
    while (offset < end) {
        IsoBox child;
        if (!ReadMemoryBox(bytes, offset, end, &child)) return false;
        if (child.type == kBoxTrun) {
            std::uint64_t trun_bytes = 0U;
            if (!ParseTrunSampleBytes(bytes, child, has_default_sample_size,
                                      default_sample_size, &trun_bytes) ||
                !AddBytes(trun_bytes, &total)) {
                return false;
            }
            found_trun = true;
        }
        offset += static_cast<std::size_t>(child.size);
    }
    // A fragment can carry an empty traf for a temporarily idle A/V stream;
    // its tfhd is still useful binding information, but it contributes no
    // mdat bytes.  The containing moof must have at least one real trun.
    if (!found_trun) {
        *sample_bytes = 0U;
        return true;
    }
    *sample_bytes = total;
    return true;
}

bool ParseMoofSampleBytes(const std::vector<unsigned char>& bytes,
                          std::uint64_t* sample_bytes) noexcept {
    if (sample_bytes == nullptr || bytes.empty()) return false;
    bool found_traf = false;
    bool found_samples = false;
    std::uint64_t total = 0U;
    std::size_t offset = 0U;
    while (offset < bytes.size()) {
        IsoBox child;
        if (!ReadMemoryBox(bytes, offset, bytes.size(), &child)) return false;
        if (child.type == kBoxTraf) {
            std::uint64_t traf_bytes = 0U;
            if (!ParseTrafSampleBytes(bytes, child, &traf_bytes)) {
                return false;
            }
            if (traf_bytes != 0U && !AddBytes(traf_bytes, &total)) return false;
            found_traf = true;
            found_samples |= traf_bytes != 0U;
        }
        offset += static_cast<std::size_t>(child.size);
    }
    if (!found_traf || !found_samples) return false;
    *sample_bytes = total;
    return true;
}

// Media Foundation can legitimately optimize fMP4 indexing from an early
// fragment.  Before trusting the reader's EOS, ensure every later recorder
// fragment is syntactically complete and that its trun sample data cannot run
// past its following mdat.  The decoder below remains the proof that the media
// itself is playable; this guard prevents an invalid later fragment from being
// mistaken for an absent tail.
bool HasCompleteFragmentedMp4Layout(const std::filesystem::path& path) {
    std::error_code error;
    const std::uintmax_t raw_file_size = std::filesystem::file_size(path, error);
    if (error || raw_file_size < 8U ||
        raw_file_size > (std::numeric_limits<std::uint64_t>::max)()) {
        return false;
    }
    const std::uint64_t file_size = static_cast<std::uint64_t>(raw_file_size);
    std::ifstream input(path, std::ios::binary);
    if (!input.good()) return false;

    bool has_pending_moof = false;
    std::uint64_t pending_sample_bytes = 0U;
    std::uint64_t offset = 0U;
    while (offset < file_size) {
        IsoBox box;
        if (!ReadFileBoxHeader(&input, file_size, offset, &box)) return false;
        if (box.type == kBoxMoof) {
            if (has_pending_moof || box.size < box.header_size ||
                box.size - box.header_size > kMaximumMoofPayloadBytes ||
                box.size - box.header_size > (std::numeric_limits<std::size_t>::max)()) {
                return false;
            }
            std::vector<unsigned char> payload(
                static_cast<std::size_t>(box.size - box.header_size));
            if (payload.empty()) return false;
            input.clear();
            input.seekg(static_cast<std::streamoff>(box.offset + box.header_size),
                        std::ios::beg);
            input.read(reinterpret_cast<char*>(payload.data()),
                       static_cast<std::streamsize>(payload.size()));
            if (!input || !ParseMoofSampleBytes(payload, &pending_sample_bytes)) {
                return false;
            }
            has_pending_moof = true;
        } else if (box.type == kBoxMdat && has_pending_moof) {
            const std::uint64_t mdat_payload_bytes = box.size - box.header_size;
            if (pending_sample_bytes == 0U ||
                pending_sample_bytes > mdat_payload_bytes) {
                return false;
            }
            has_pending_moof = false;
            pending_sample_bytes = 0U;
        }
        offset += box.size;
    }
    return !has_pending_moof;
}

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

bool HasExpectedCurrentType(IMFSourceReader* reader,
                            DWORD stream,
                            const GUID& major_type,
                            const GUID& subtype) noexcept {
    ComPtr<IMFMediaType> current_type;
    GUID actual_major{};
    GUID actual_subtype{};
    return SUCCEEDED(reader->GetCurrentMediaType(stream, &current_type)) &&
           current_type != nullptr &&
           SUCCEEDED(current_type->GetGUID(MF_MT_MAJOR_TYPE, &actual_major)) &&
           SUCCEEDED(current_type->GetGUID(MF_MT_SUBTYPE, &actual_subtype)) &&
           actual_major == major_type && actual_subtype == subtype;
}

// A source reader can emit stream ticks (no IMFSample) between real samples,
// but a finalized recording must not spin forever without either producing
// data or reaching EOS.  This is deliberately a *no-progress* bound, not a
// total-sample bound: long recordings must be decoded all the way through.
constexpr std::uint32_t kMaximumConsecutiveNoProgressReads = 128U;

bool DecodeRequiredStreamThroughEndOfStream(
    IMFSourceReader* reader,
    DWORD stream,
    const GUID& expected_decoded_major_type,
    const GUID& expected_decoded_subtype,
    std::uint64_t* decoded_samples,
    const char** failure_detail) noexcept {
    if (failure_detail != nullptr) *failure_detail = nullptr;
    if (reader == nullptr || decoded_samples == nullptr) {
        if (failure_detail != nullptr) *failure_detail = "MP4 source reader arguments are invalid.";
        return false;
    }

    *decoded_samples = 0U;
    std::uint32_t consecutive_no_progress_reads = 0U;
    bool saw_initial_current_type_change = false;
    for (;;) {
        DWORD flags = 0U;
        ComPtr<IMFSample> sample;
        const HRESULT hr = reader->ReadSample(
            stream, 0U, nullptr, &flags, nullptr, &sample);

        // Any decoder/parser error or format transition means the candidate
        // was not decoded continuously to the end.  Do not promote a file
        // merely because its beginning happens to be readable.
        constexpr DWORD kAlwaysRejectedFlags =
            MF_SOURCE_READERF_ERROR |
            MF_SOURCE_READERF_NEWSTREAM |
            MF_SOURCE_READERF_NATIVEMEDIATYPECHANGED;
        const bool current_type_changed =
            (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0U;
        // SetCurrentMediaType may result in exactly one notification before
        // the first decoded sample. It is the requested PCM/NV12 format, not
        // a mid-stream transition. Verify it and reject every later change.
        const bool initial_requested_type_change =
            current_type_changed && !saw_initial_current_type_change &&
            *decoded_samples == 0U &&
            HasExpectedCurrentType(reader, stream, expected_decoded_major_type,
                                   expected_decoded_subtype);
        if (initial_requested_type_change) {
            saw_initial_current_type_change = true;
        }
        if (FAILED(hr) || (flags & kAlwaysRejectedFlags) != 0U ||
            (current_type_changed && !initial_requested_type_change)) {
            if (failure_detail != nullptr) {
                if (FAILED(hr)) {
                    *failure_detail = "Media Foundation failed while decoding the stream.";
                } else if ((flags & MF_SOURCE_READERF_ERROR) != 0U) {
                    *failure_detail = "Media Foundation reported a decode error.";
                } else if ((flags & MF_SOURCE_READERF_NEWSTREAM) != 0U) {
                    *failure_detail = "Media Foundation reported an unexpected new stream.";
                } else if ((flags & MF_SOURCE_READERF_NATIVEMEDIATYPECHANGED) != 0U) {
                    *failure_detail = "Media Foundation reported a native media-type change.";
                } else {
                    *failure_detail = "Media Foundation reported a mid-stream decoded media-type change.";
                }
            }
            return false;
        }

        if (sample != nullptr) {
            ComPtr<IMFMediaBuffer> buffer;
            DWORD bytes = 0U;
            const HRESULT buffer_result = sample->ConvertToContiguousBuffer(&buffer);
            if (FAILED(buffer_result) || buffer == nullptr ||
                FAILED(buffer->GetCurrentLength(&bytes)) || bytes == 0U) {
                if (failure_detail != nullptr) {
                    *failure_detail = "Media Foundation returned an empty or malformed decoded sample.";
                }
                return false;
            }
            ++*decoded_samples;
            consecutive_no_progress_reads = 0U;
        } else if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) == 0U) {
            ++consecutive_no_progress_reads;
            if (consecutive_no_progress_reads >
                kMaximumConsecutiveNoProgressReads) {
                if (failure_detail != nullptr) {
                    *failure_detail = "Media Foundation did not make decode progress or reach end-of-stream.";
                }
                return false;
            }
        }

        // A stream that reaches EOS before yielding a decoded sample is not a
        // recoverable recording.  EOS with a final non-empty sample is valid.
        if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0U) {
            if (*decoded_samples == 0U && failure_detail != nullptr) {
                *failure_detail = "Media Foundation reached end-of-stream without a decoded sample.";
            }
            return *decoded_samples != 0U;
        }
    }
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
    try {
        if (!HasCompleteFragmentedMp4Layout(path)) {
            return Fail(Error::VideoDecodeFailed, detail,
                        "Finalized MP4 has an incomplete or inconsistent fragmented-MP4 tail.");
        }
    } catch (...) {
        return Fail(Error::VideoDecodeFailed, detail,
                    "Finalized MP4 fragment validation could not complete safely.");
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
    const char* decode_detail = nullptr;
    if (FAILED(ConfigureVideoDecoder(reader.Get())) ||
        !DecodeRequiredStreamThroughEndOfStream(
            reader.Get(), kVideoStream, MFMediaType_Video, MFVideoFormat_NV12,
            &report->decoded_video_samples,
            &decode_detail)) {
        return Fail(Error::VideoDecodeFailed, detail,
                    decode_detail != nullptr ? decode_detail :
                        "Media Foundation could not decode the complete H.264 stream through end-of-stream.");
    }

    reader.Reset();
    const HRESULT reopen = MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader);
    if (FAILED(reopen) || reader == nullptr) {
        return Fail(Error::SourceReaderFailed, detail,
                    "Media Foundation could not reopen finalized MP4 output for AAC validation.");
    }
    decode_detail = nullptr;
    if (FAILED(ConfigureAudioDecoder(reader.Get())) ||
        !DecodeRequiredStreamThroughEndOfStream(
            reader.Get(), kAudioStream, MFMediaType_Audio, MFAudioFormat_PCM,
            &report->decoded_audio_samples,
            &decode_detail)) {
        return Fail(Error::AudioDecodeFailed, detail,
                    decode_detail != nullptr ? decode_detail :
                        "Media Foundation could not decode the complete AAC stream through end-of-stream.");
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
    try {
        if (!HasCompleteFragmentedMp4Layout(path)) {
            return Fail(Error::AudioDecodeFailed, detail,
                        "Finalized audio output has an incomplete or inconsistent fragmented-MP4 tail.");
        }
    } catch (...) {
        return Fail(Error::AudioDecodeFailed, detail,
                    "Finalized audio fragment validation could not complete safely.");
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
    const char* decode_detail = nullptr;
    if (FAILED(ConfigureAudioDecoder(reader.Get())) ||
        !DecodeRequiredStreamThroughEndOfStream(
            reader.Get(), kAudioStream, MFMediaType_Audio, MFAudioFormat_PCM,
            &report->decoded_audio_samples,
            &decode_detail)) {
        return Fail(Error::AudioDecodeFailed, detail,
                    decode_detail != nullptr ? decode_detail :
                        "Media Foundation could not decode the complete AAC stream through end-of-stream.");
    }
    if (detail != nullptr) detail->clear();
    return Error::Ok;
}

}  // namespace recorder::mp4::validation
