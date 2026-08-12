#include "mix_format_decoder.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmreg.h>

#include <cmath>
#include <cstring>
#include <limits>

namespace recorder::format {
namespace {

void SetError(DecodeError value, DecodeError* error) {
    if (error != nullptr) { *error = value; }
}

bool MultiplyFits(std::size_t left, std::size_t right, std::size_t* result) {
    if (left != 0 && right > std::numeric_limits<std::size_t>::max() / left) { return false; }
    *result = left * right;
    return true;
}

bool IsSupportedPcmBits(WORD bits) {
    return bits == 8 || bits == 16 || bits == 24 || bits == 32;
}

bool IsExpectedBlockAlign(const MixFormat& format) {
    const std::size_t bytes_per_sample = format.bits_per_sample / 8;
    std::size_t expected = 0;
    return MultiplyFits(format.channels, bytes_per_sample, &expected) && expected == format.block_align;
}

float DecodeSample(const std::uint8_t* bytes, const MixFormat& format) {
    switch (format.encoding) {
    case SampleEncoding::IeeeFloat: {
        float value = 0.0F;
        std::memcpy(&value, bytes, sizeof(value));
        return std::isfinite(value) ? value : 0.0F;
    }
    case SampleEncoding::PcmInteger:
        switch (format.bits_per_sample) {
        case 8: return (static_cast<int>(bytes[0]) - 128) / 128.0F;
        case 16: {
            std::int16_t value = 0;
            std::memcpy(&value, bytes, sizeof(value));
            return static_cast<float>(value) / 32768.0F;
        }
        case 24: {
            std::int32_t value = static_cast<std::int32_t>(bytes[0]) |
                                 (static_cast<std::int32_t>(bytes[1]) << 8) |
                                 (static_cast<std::int32_t>(bytes[2]) << 16);
            if ((value & 0x00800000) != 0) { value |= ~0x00FFFFFF; }
            return static_cast<float>(value) / 8388608.0F;
        }
        case 32: {
            std::int32_t value = 0;
            std::memcpy(&value, bytes, sizeof(value));
            return static_cast<float>(value) / 2147483648.0F;
        }
        default: return 0.0F;  // Guarded by DecodeMixFormat.
        }
    }
    return 0.0F;
}

}  // namespace

bool DecodeMixFormat(const std::uint8_t* format_bytes, std::size_t format_byte_count,
                     MixFormat* output, DecodeError* error) {
    if (output == nullptr || format_bytes == nullptr) { SetError(DecodeError::InvalidArgument, error); return false; }
    if (format_byte_count < sizeof(WAVEFORMATEX)) { SetError(DecodeError::TruncatedFormat, error); return false; }

    WAVEFORMATEX base{};
    std::memcpy(&base, format_bytes, sizeof(base));
    if (base.nChannels == 0 || base.nSamplesPerSec == 0 || base.nBlockAlign == 0) {
        SetError(DecodeError::InvalidFormat, error); return false;
    }
    if (base.cbSize > format_byte_count - sizeof(WAVEFORMATEX)) {
        SetError(DecodeError::TruncatedFormat, error); return false;
    }

    MixFormat decoded;
    decoded.sample_rate = base.nSamplesPerSec;
    decoded.channels = base.nChannels;
    decoded.block_align = base.nBlockAlign;
    decoded.bits_per_sample = base.wBitsPerSample;
    if (base.wFormatTag == WAVE_FORMAT_PCM) {
        if (!IsSupportedPcmBits(base.wBitsPerSample)) { SetError(DecodeError::UnsupportedFormat, error); return false; }
        decoded.encoding = SampleEncoding::PcmInteger;
    } else if (base.wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        if (base.wBitsPerSample != 32) { SetError(DecodeError::UnsupportedFormat, error); return false; }
        decoded.encoding = SampleEncoding::IeeeFloat;
    } else if (base.wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        constexpr std::size_t kExtensibleTailSize = sizeof(WORD) + sizeof(DWORD) + sizeof(GUID);
        if (base.cbSize < kExtensibleTailSize || format_byte_count < sizeof(WAVEFORMATEX) + kExtensibleTailSize) {
            SetError(DecodeError::TruncatedFormat, error); return false;
        }
        GUID sub_format{};
        std::memcpy(&sub_format, format_bytes + sizeof(WAVEFORMATEX) + sizeof(WORD) + sizeof(DWORD), sizeof(sub_format));
        if (sub_format == KSDATAFORMAT_SUBTYPE_PCM) {
            if (!IsSupportedPcmBits(base.wBitsPerSample)) { SetError(DecodeError::UnsupportedFormat, error); return false; }
            decoded.encoding = SampleEncoding::PcmInteger;
        } else if (sub_format == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT && base.wBitsPerSample == 32) {
            decoded.encoding = SampleEncoding::IeeeFloat;
        } else {
            SetError(DecodeError::UnsupportedFormat, error); return false;
        }
    } else {
        SetError(DecodeError::UnsupportedFormat, error); return false;
    }

    if (!IsExpectedBlockAlign(decoded)) { SetError(DecodeError::InvalidFormat, error); return false; }
    *output = decoded;
    SetError(DecodeError::None, error);
    return true;
}

bool ConvertPacketToInterleavedFloat(const MixFormat& format, const CapturePacketView& packet,
                                     std::vector<float>* output, DecodeError* error) {
    if (output == nullptr || format.channels == 0 || format.block_align == 0 || !IsExpectedBlockAlign(format)) {
        SetError(DecodeError::InvalidArgument, error); return false;
    }
    std::size_t required_bytes = 0;
    std::size_t sample_count = 0;
    if (!MultiplyFits(packet.frame_count, format.block_align, &required_bytes) ||
        !MultiplyFits(packet.frame_count, format.channels, &sample_count)) {
        SetError(DecodeError::Overflow, error); return false;
    }
    if (packet.byte_count != 0 && packet.byte_count % format.block_align != 0) {
        SetError(DecodeError::BadPacketAlignment, error); return false;
    }
    if (!packet.silent) {
        if (packet.data == nullptr) { SetError(DecodeError::InvalidArgument, error); return false; }
        if (packet.byte_count < required_bytes) { SetError(DecodeError::TruncatedPacket, error); return false; }
        if (packet.byte_count != required_bytes) { SetError(DecodeError::PacketLengthMismatch, error); return false; }
    } else if (packet.byte_count != 0 && packet.byte_count != required_bytes) {
        SetError(DecodeError::PacketLengthMismatch, error); return false;
    }

    try { output->assign(sample_count, 0.0F); }
    catch (const std::bad_alloc&) { SetError(DecodeError::Overflow, error); return false; }
    if (packet.silent) { SetError(DecodeError::None, error); return true; }

    const std::size_t bytes_per_sample = format.bits_per_sample / 8;
    for (std::size_t frame = 0; frame < packet.frame_count; ++frame) {
        const std::uint8_t* frame_bytes = packet.data + frame * format.block_align;
        for (std::size_t channel = 0; channel < format.channels; ++channel) {
            (*output)[frame * format.channels + channel] = DecodeSample(frame_bytes + channel * bytes_per_sample, format);
        }
    }
    SetError(DecodeError::None, error);
    return true;
}

}  // namespace recorder::format
