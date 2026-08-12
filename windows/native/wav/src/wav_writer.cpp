#include "wav_writer.h"

#include <array>
#include <cstring>
#include <fstream>
#include <limits>
#include <utility>

namespace recorder::wav {
namespace {

void PutU16(std::array<char, 44>& header, std::size_t offset, std::uint16_t value) {
    header[offset] = static_cast<char>(value & 0xffU);
    header[offset + 1] = static_cast<char>((value >> 8U) & 0xffU);
}

void PutU32(std::array<char, 44>& header, std::size_t offset, std::uint32_t value) {
    for (std::size_t index = 0; index != 4; ++index) {
        header[offset + index] = static_cast<char>((value >> (index * 8U)) & 0xffU);
    }
}

bool IsLittleEndian() {
    const std::uint16_t value = 1;
    return *reinterpret_cast<const unsigned char*>(&value) == 1;
}

}  // namespace

class Writer::StreamHolder final {
public:
    std::ofstream value;
};

Writer::Writer(std::filesystem::path final_path, std::uint32_t sample_rate, std::uint16_t channels)
    : final_path_(std::move(final_path)),
      partial_path_(final_path_),
      sample_rate_(sample_rate),
      channels_(channels),
      block_align_(static_cast<std::uint16_t>(channels * sizeof(float))),
      byte_rate_(sample_rate * static_cast<std::uint32_t>(channels * sizeof(float))),
      stream_(std::make_unique<StreamHolder>()) {
    partial_path_ += std::filesystem::path(".partial").native();
}

Writer::~Writer() {
    if (stream_ && stream_->value.is_open()) {
        stream_->value.close();
    }
}

std::unique_ptr<Writer> Writer::Create(
    const std::filesystem::path& final_path,
    std::uint32_t sample_rate,
    std::uint16_t channels,
    Error* error) {
    if (error == nullptr) return nullptr;
    *error = Error::InvalidArgument;
    if (final_path.empty() || sample_rate == 0 || channels == 0 ||
        channels > std::numeric_limits<std::uint16_t>::max() / sizeof(float)) {
        return nullptr;
    }
    const auto block_align = static_cast<std::uint32_t>(channels) * sizeof(float);
    if (sample_rate > std::numeric_limits<std::uint32_t>::max() / block_align) return nullptr;

    std::error_code ec;
    if (std::filesystem::exists(final_path, ec) || ec) {
        *error = ec ? Error::IoError : Error::AlreadyExists;
        return nullptr;
    }
    auto writer = std::unique_ptr<Writer>(new Writer(final_path, sample_rate, channels));
    *error = writer->Open();
    return *error == Error::Ok ? std::move(writer) : nullptr;
}

Error Writer::Open() {
    std::error_code ec;
    if (std::filesystem::exists(partial_path_, ec)) return ec ? Error::IoError : Error::AlreadyExists;
    stream_->value.open(partial_path_, std::ios::binary | std::ios::out);
    if (!stream_->value.is_open()) return Error::IoError;
    return WriteHeader(36U, 0U);
}

Error Writer::WriteHeader(std::uint32_t riff_size, std::uint32_t data_size) {
    std::array<char, 44> header{};
    header[0] = 'R'; header[1] = 'I'; header[2] = 'F'; header[3] = 'F';
    PutU32(header, 4, riff_size);
    header[8] = 'W'; header[9] = 'A'; header[10] = 'V'; header[11] = 'E';
    header[12] = 'f'; header[13] = 'm'; header[14] = 't'; header[15] = ' ';
    PutU32(header, 16, 16U);
    PutU16(header, 20, 3U);  // WAVE_FORMAT_IEEE_FLOAT
    PutU16(header, 22, channels_);
    PutU32(header, 24, sample_rate_);
    PutU32(header, 28, byte_rate_);
    PutU16(header, 32, block_align_);
    PutU16(header, 34, 32U);
    header[36] = 'd'; header[37] = 'a'; header[38] = 't'; header[39] = 'a';
    PutU32(header, 40, data_size);
    stream_->value.seekp(0);
    stream_->value.write(header.data(), static_cast<std::streamsize>(header.size()));
    return stream_->value ? Error::Ok : Error::IoError;
}

Error Writer::WriteFrames(const float* interleaved_frames, std::uint64_t frame_count) {
    if (finalized_ || aborted_) return Error::InvalidState;
    if (frame_count == 0) return Error::Ok;
    if (interleaved_frames == nullptr) return Error::InvalidArgument;
    const auto bytes_per_frame = static_cast<std::uint64_t>(block_align_);
    if (frame_count > std::numeric_limits<std::uint32_t>::max() / bytes_per_frame ||
        data_bytes_ > std::numeric_limits<std::uint32_t>::max() - frame_count * bytes_per_frame ||
        frame_count > std::numeric_limits<std::size_t>::max() / block_align_) {
        return Error::Overflow;
    }
    const auto bytes = static_cast<std::size_t>(frame_count * bytes_per_frame);
    static_assert(sizeof(float) == 4 && std::numeric_limits<float>::is_iec559,
                  "WAV IEEE float output requires 32-bit IEC 559 floats");
    if (IsLittleEndian()) {
        stream_->value.write(reinterpret_cast<const char*>(interleaved_frames), static_cast<std::streamsize>(bytes));
    } else {
        const auto samples = static_cast<std::size_t>(frame_count) * channels_;
        for (std::size_t index = 0; index != samples; ++index) {
            std::uint32_t bits = 0;
            std::memcpy(&bits, &interleaved_frames[index], sizeof(bits));
            const char little_endian[4] = {
                static_cast<char>(bits & 0xffU),
                static_cast<char>((bits >> 8U) & 0xffU),
                static_cast<char>((bits >> 16U) & 0xffU),
                static_cast<char>((bits >> 24U) & 0xffU),
            };
            stream_->value.write(little_endian, sizeof(little_endian));
        }
    }
    if (!stream_->value) return Error::IoError;
    data_bytes_ += static_cast<std::uint32_t>(bytes);
    return Error::Ok;
}

Error Writer::Finalize() {
    if (finalized_ || aborted_) return Error::InvalidState;
    const auto riff_size = static_cast<std::uint64_t>(36U) + data_bytes_;
    if (riff_size > std::numeric_limits<std::uint32_t>::max()) return Error::Overflow;
    if (WriteHeader(static_cast<std::uint32_t>(riff_size), data_bytes_) != Error::Ok) return Error::IoError;
    stream_->value.flush();
    if (!stream_->value) return Error::IoError;
    stream_->value.close();

    std::error_code ec;
    if (std::filesystem::exists(final_path_, ec)) return ec ? Error::IoError : Error::AlreadyExists;
    std::filesystem::rename(partial_path_, final_path_, ec);
    if (ec) return Error::IoError;
    finalized_ = true;
    return Error::Ok;
}

void Writer::Abort() {
    if (finalized_ || aborted_) return;
    if (stream_->value.is_open()) stream_->value.close();
    aborted_ = true;
}

}  // namespace recorder::wav
