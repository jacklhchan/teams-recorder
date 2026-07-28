#include "../mix_format_decoder.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmreg.h>

#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>
#include <vector>

namespace {

using recorder::format::CapturePacketView;
using recorder::format::DecodeError;
using recorder::format::MixFormat;

bool Expect(bool condition, const char* message) {
    if (!condition) { std::cerr << message << '\n'; }
    return condition;
}

WAVEFORMATEX Base(WORD tag, WORD channels, DWORD rate, WORD bits) {
    WAVEFORMATEX value{};
    value.wFormatTag = tag; value.nChannels = channels; value.nSamplesPerSec = rate;
    value.wBitsPerSample = bits; value.nBlockAlign = static_cast<WORD>(channels * (bits / 8));
    value.nAvgBytesPerSec = value.nSamplesPerSec * value.nBlockAlign;
    return value;
}

std::vector<std::uint8_t> Bytes(const WAVEFORMATEX& format) {
    std::vector<std::uint8_t> bytes(sizeof(format));
    std::memcpy(bytes.data(), &format, sizeof(format));
    return bytes;
}

std::vector<std::uint8_t> Extensible(const GUID& subtype, WORD channels, WORD bits) {
    WAVEFORMATEXTENSIBLE format{};
    format.Format = Base(WAVE_FORMAT_EXTENSIBLE, channels, 48000, bits);
    format.Format.cbSize = 22;
    format.Samples.wValidBitsPerSample = bits;
    format.SubFormat = subtype;
    std::vector<std::uint8_t> bytes(sizeof(format));
    std::memcpy(bytes.data(), &format, sizeof(format));
    return bytes;
}

bool Parse(const std::vector<std::uint8_t>& bytes, MixFormat* format) {
    DecodeError error = DecodeError::None;
    return Expect(recorder::format::DecodeMixFormat(bytes.data(), bytes.size(), format, &error), "format parse failed");
}

}  // namespace

int main() {
    MixFormat format;
    std::vector<float> samples;
    DecodeError error = DecodeError::None;

    const auto float_format = Bytes(Base(WAVE_FORMAT_IEEE_FLOAT, 2, 48000, 32));
    if (!Parse(float_format, &format)) { return 1; }
    float float_input[] = { 0.5F, std::numeric_limits<float>::infinity(), std::numeric_limits<float>::quiet_NaN(), -0.25F };
    if (!Expect(recorder::format::ConvertPacketToInterleavedFloat(format,
            { reinterpret_cast<const std::uint8_t*>(float_input), sizeof(float_input), 2, false }, &samples, &error), "float convert failed") ||
        !Expect(samples.size() == 4 && samples[0] == 0.5F && samples[1] == 0.0F && samples[2] == 0.0F && samples[3] == -0.25F, "float NaN/Inf handling failed")) { return 1; }

    const auto pcm16 = Bytes(Base(WAVE_FORMAT_PCM, 1, 48000, 16));
    if (!Parse(pcm16, &format)) { return 1; }
    const std::int16_t mono_input[] = { -32768, 16384 };
    if (!Expect(recorder::format::ConvertPacketToInterleavedFloat(format,
            { reinterpret_cast<const std::uint8_t*>(mono_input), sizeof(mono_input), 2, false }, &samples, &error), "PCM16 convert failed") ||
        !Expect(samples[0] == -1.0F && samples[1] == 0.5F, "mono PCM16 scaling failed")) { return 1; }

    const auto pcm24 = Bytes(Base(WAVE_FORMAT_PCM, 1, 48000, 24));
    if (!Parse(pcm24, &format)) { return 1; }
    const std::uint8_t pcm24_input[] = { 0x00, 0x00, 0x80 };
    if (!Expect(recorder::format::ConvertPacketToInterleavedFloat(format, { pcm24_input, 3, 1, false }, &samples, &error), "PCM24 convert failed") ||
        !Expect(samples[0] == -1.0F, "PCM24 sign extension failed")) { return 1; }

    if (!Parse(Extensible(KSDATAFORMAT_SUBTYPE_PCM, 1, 16), &format) || !Expect(format.bits_per_sample == 16, "extensible PCM parse failed") ||
        !Parse(Extensible(KSDATAFORMAT_SUBTYPE_IEEE_FLOAT, 1, 32), &format) || !Expect(format.encoding == recorder::format::SampleEncoding::IeeeFloat, "extensible float parse failed")) { return 1; }

    if (!Expect(recorder::format::ConvertPacketToInterleavedFloat(format, { nullptr, 0, 2, true }, &samples, &error), "silent conversion failed") ||
        !Expect(samples.size() == 2 && samples[0] == 0.0F && samples[1] == 0.0F, "silent packet must produce zeroes")) { return 1; }

    if (!Expect(!recorder::format::ConvertPacketToInterleavedFloat(format, { nullptr, 2, 1, false }, &samples, &error) && error == DecodeError::BadPacketAlignment, "bad alignment must fail") ||
        !Expect(!recorder::format::ConvertPacketToInterleavedFloat(format, { reinterpret_cast<const std::uint8_t*>("xxxx"), 4, 2, false }, &samples, &error) && error == DecodeError::TruncatedPacket, "truncated packet must fail")) { return 1; }
    const std::uint8_t short_format[] = { 1, 0 };
    if (!Expect(!recorder::format::DecodeMixFormat(short_format, sizeof(short_format), &format, &error) && error == DecodeError::TruncatedFormat, "truncated format must fail")) { return 1; }
    return 0;
}
