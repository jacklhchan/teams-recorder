#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace recorder::format {

enum class SampleEncoding { PcmInteger, IeeeFloat };

enum class DecodeError {
    None,
    InvalidArgument,
    TruncatedFormat,
    UnsupportedFormat,
    InvalidFormat,
    Overflow,
    BadPacketAlignment,
    TruncatedPacket,
    PacketLengthMismatch,
};

struct MixFormat {
    std::uint32_t sample_rate = 0;
    std::uint16_t channels = 0;
    std::uint16_t block_align = 0;
    std::uint16_t bits_per_sample = 0;
    SampleEncoding encoding = SampleEncoding::PcmInteger;
};

struct CapturePacketView {
    const std::uint8_t* data = nullptr;
    std::size_t byte_count = 0;
    std::uint32_t frame_count = 0;
    bool silent = false;
};

// Parses an owned WAVEFORMATEX or WAVEFORMATEXTENSIBLE byte blob without retaining it.
bool DecodeMixFormat(const std::uint8_t* format_bytes, std::size_t format_byte_count,
                     MixFormat* output, DecodeError* error);

// Converts one interleaved packet. Silent packets produce zeroes even when their data pointer is null.
bool ConvertPacketToInterleavedFloat(const MixFormat& format, const CapturePacketView& packet,
                                     std::vector<float>* output, DecodeError* error);

}  // namespace recorder::format
