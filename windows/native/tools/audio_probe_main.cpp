#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "wasapi_capture.h"
#include "wav_writer.h"

#include <audioclient.h>
#include <ksmedia.h>
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

using recorder::audio::AudioBlock;
using recorder::audio::CaptureError;
using recorder::audio::CaptureRequest;
using recorder::audio::EndpointFlow;
using recorder::audio::EndpointInfo;
using recorder::audio::WasapiCapture;
using recorder::wav::Error;
using recorder::wav::Writer;

enum class SampleEncoding {
    Float32,
    Pcm8,
    Pcm16,
    Pcm24,
    Pcm32,
};

struct FormatInfo {
    std::uint32_t sample_rate = 0;
    std::uint16_t channels = 0;
    std::uint16_t block_align = 0;
    std::uint16_t bits_per_sample = 0;
    SampleEncoding encoding = SampleEncoding::Float32;
};

struct ProbeStats {
    std::uint64_t packets = 0;
    std::uint64_t frames = 0;
    std::uint64_t silent_packets = 0;
    std::uint64_t discontinuities = 0;
    std::uint64_t first_device_position = 0;
    std::uint64_t last_device_position = 0;
    std::uint64_t first_qpc_position = 0;
    std::uint64_t last_qpc_position = 0;
    float peak = 0.0F;
    bool event_driven = true;
};

std::string WideToUtf8(const std::wstring& value) {
    if (value.empty()) {
        return {};
    }
    const int required = WideCharToMultiByte(
        CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (required <= 0) {
        return "<encoding-error>";
    }
    std::string result(static_cast<std::size_t>(required), '\0');
    WideCharToMultiByte(
        CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), required, nullptr, nullptr);
    return result;
}

std::string HResultText(HRESULT result) {
    std::ostringstream stream;
    stream << "0x" << std::hex << std::uppercase << static_cast<std::uint32_t>(result);
    return stream.str();
}

bool ParsePositiveSeconds(const wchar_t* text, std::uint32_t* seconds) {
    if (text == nullptr || seconds == nullptr || *text == L'\0') {
        return false;
    }
    std::uint64_t value = 0;
    for (const wchar_t* cursor = text; *cursor != L'\0'; ++cursor) {
        if (*cursor < L'0' || *cursor > L'9') {
            return false;
        }
        value = value * 10U + static_cast<std::uint64_t>(*cursor - L'0');
        if (value > 300U) {
            return false;
        }
    }
    if (value == 0) {
        return false;
    }
    *seconds = static_cast<std::uint32_t>(value);
    return true;
}

template <typename T>
bool ReadObject(const std::vector<std::uint8_t>& bytes, std::size_t offset, T* value) {
    if (value == nullptr || offset > bytes.size() || bytes.size() - offset < sizeof(T)) {
        return false;
    }
    std::memcpy(value, bytes.data() + offset, sizeof(T));
    return true;
}

bool ParseFormat(const std::vector<std::uint8_t>& bytes, FormatInfo* format, std::string* error) {
    if (format == nullptr || error == nullptr || bytes.size() < sizeof(WAVEFORMATEX)) {
        if (error != nullptr) {
            *error = "WASAPI returned a truncated WAVEFORMATEX.";
        }
        return false;
    }

    WAVEFORMATEX wave{};
    std::memcpy(&wave, bytes.data(), sizeof(wave));
    if (wave.nChannels == 0 || wave.nSamplesPerSec == 0 || wave.nBlockAlign == 0) {
        *error = "WASAPI returned an invalid channel, sample-rate, or block-align value.";
        return false;
    }

    WORD tag = wave.wFormatTag;
    GUID sub_format{};
    if (tag == WAVE_FORMAT_EXTENSIBLE) {
        WAVEFORMATEXTENSIBLE extensible{};
        if (!ReadObject(bytes, 0, &extensible)) {
            *error = "WASAPI returned a truncated WAVEFORMATEXTENSIBLE.";
            return false;
        }
        sub_format = extensible.SubFormat;
        if (IsEqualGUID(sub_format, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) {
            tag = WAVE_FORMAT_IEEE_FLOAT;
        } else if (IsEqualGUID(sub_format, KSDATAFORMAT_SUBTYPE_PCM)) {
            tag = WAVE_FORMAT_PCM;
        } else {
            *error = "The endpoint mix format has an unsupported extensible sub-format.";
            return false;
        }
    }

    SampleEncoding encoding{};
    if (tag == WAVE_FORMAT_IEEE_FLOAT && wave.wBitsPerSample == 32) {
        encoding = SampleEncoding::Float32;
    } else if (tag == WAVE_FORMAT_PCM && wave.wBitsPerSample == 8) {
        encoding = SampleEncoding::Pcm8;
    } else if (tag == WAVE_FORMAT_PCM && wave.wBitsPerSample == 16) {
        encoding = SampleEncoding::Pcm16;
    } else if (tag == WAVE_FORMAT_PCM && wave.wBitsPerSample == 24) {
        encoding = SampleEncoding::Pcm24;
    } else if (tag == WAVE_FORMAT_PCM && wave.wBitsPerSample == 32) {
        encoding = SampleEncoding::Pcm32;
    } else {
        *error = "The endpoint mix format is not float32 or supported integer PCM.";
        return false;
    }

    const std::uint32_t expected_align =
        static_cast<std::uint32_t>(wave.nChannels) * (wave.wBitsPerSample / 8U);
    if (wave.wBitsPerSample % 8U != 0 || expected_align != wave.nBlockAlign) {
        *error = "The endpoint block alignment is not supported by this probe.";
        return false;
    }

    *format = {
        wave.nSamplesPerSec,
        wave.nChannels,
        wave.nBlockAlign,
        wave.wBitsPerSample,
        encoding,
    };
    return true;
}

float DecodePcmSample(
    const std::uint8_t* source,
    SampleEncoding encoding) {
    switch (encoding) {
    case SampleEncoding::Float32: {
        float value = 0.0F;
        std::memcpy(&value, source, sizeof(value));
        return std::isfinite(value) ? value : 0.0F;
    }
    case SampleEncoding::Pcm8:
        return (static_cast<int>(*source) - 128) / 128.0F;
    case SampleEncoding::Pcm16: {
        std::int16_t value = 0;
        std::memcpy(&value, source, sizeof(value));
        return static_cast<float>(value) / 32768.0F;
    }
    case SampleEncoding::Pcm24: {
        std::int32_t value =
            static_cast<std::int32_t>(source[0]) |
            (static_cast<std::int32_t>(source[1]) << 8) |
            (static_cast<std::int32_t>(source[2]) << 16);
        if ((value & 0x00800000) != 0) {
            value |= static_cast<std::int32_t>(0xFF000000);
        }
        return static_cast<float>(value) / 8388608.0F;
    }
    case SampleEncoding::Pcm32: {
        std::int32_t value = 0;
        std::memcpy(&value, source, sizeof(value));
        return static_cast<float>(static_cast<double>(value) / 2147483648.0);
    }
    }
    return 0.0F;
}

bool DecodeBlock(
    const AudioBlock& block,
    const FormatInfo& format,
    std::vector<float>* samples,
    std::string* error) {
    if (samples == nullptr || error == nullptr) {
        return false;
    }
    if (block.frame_count >
        std::numeric_limits<std::size_t>::max() / static_cast<std::size_t>(format.channels)) {
        *error = "Captured frame count overflows the probe sample buffer.";
        return false;
    }
    const std::size_t sample_count =
        static_cast<std::size_t>(block.frame_count) * format.channels;
    samples->assign(sample_count, 0.0F);
    if (block.silent) {
        return true;
    }
    const std::size_t required =
        static_cast<std::size_t>(block.frame_count) * format.block_align;
    if (block.bytes.size() != required) {
        *error = "Captured packet byte count does not match its frame count.";
        return false;
    }

    const std::size_t bytes_per_sample = format.bits_per_sample / 8U;
    for (std::size_t index = 0; index < sample_count; ++index) {
        (*samples)[index] =
            DecodePcmSample(block.bytes.data() + index * bytes_per_sample, format.encoding);
    }
    return true;
}

std::string DefaultFlagsText(std::uint32_t flags) {
    std::string text;
    const auto append = [&text](const char* value) {
        if (!text.empty()) {
            text += ",";
        }
        text += value;
    };
    if ((flags & recorder::audio::DefaultForConsole) != 0) {
        append("console");
    }
    if ((flags & recorder::audio::DefaultForMultimedia) != 0) {
        append("multimedia");
    }
    if ((flags & recorder::audio::DefaultForCommunications) != 0) {
        append("communications");
    }
    return text.empty() ? "-" : text;
}

int ListEndpoints() {
    std::vector<EndpointInfo> endpoints;
    CaptureError error;
    const HRESULT result = WasapiCapture::EnumerateEndpoints(&endpoints, &error);
    if (FAILED(result)) {
        std::cerr << "Endpoint enumeration failed (" << HResultText(result) << "): "
                  << WideToUtf8(error.message) << "\n";
        return 1;
    }
    for (const auto& endpoint : endpoints) {
        std::cout << (endpoint.flow == EndpointFlow::Render ? "render" : "capture")
                  << "\t" << WideToUtf8(endpoint.friendly_name)
                  << "\tdefaults=" << DefaultFlagsText(endpoint.default_flags)
                  << "\t" << WideToUtf8(endpoint.endpoint_id) << "\n";
    }
    std::cout << "endpointCount=" << endpoints.size() << "\n";
    return 0;
}

int Capture(
    EndpointFlow flow,
    std::uint32_t seconds,
    const std::filesystem::path& output,
    std::wstring endpoint_id) {
    std::error_code filesystem_error;
    const auto parent = output.parent_path();
    if (!parent.empty()) {
        std::filesystem::create_directories(parent, filesystem_error);
    }
    if (filesystem_error) {
        std::cerr << "Cannot create output directory: " << filesystem_error.message() << "\n";
        return 1;
    }

    std::unique_ptr<Writer> writer;
    std::vector<std::uint8_t> source_format;
    FormatInfo format;
    ProbeStats stats;
    std::string callback_error;
    std::vector<float> decoded;

    WasapiCapture capture;
    CaptureRequest request;
    request.flow = flow;
    request.endpoint_id = std::move(endpoint_id);
    const bool started = capture.Start(
        std::move(request),
        [&](AudioBlock&& block) {
            if (!callback_error.empty()) {
                return;
            }
            if (!writer) {
                if (!ParseFormat(block.mix_format_bytes, &format, &callback_error)) {
                    return;
                }
                source_format = block.mix_format_bytes;
                Error writer_error = Error::Ok;
                writer = Writer::Create(
                    output, format.sample_rate, format.channels, &writer_error);
                if (!writer) {
                    callback_error =
                        "WAV writer creation failed with code " +
                        std::to_string(static_cast<int>(writer_error)) + ".";
                    return;
                }
            } else if (block.mix_format_bytes != source_format) {
                callback_error = "The endpoint mix format changed during capture.";
                return;
            }

            if (!DecodeBlock(block, format, &decoded, &callback_error)) {
                return;
            }
            const Error write_result =
                writer->WriteFrames(decoded.data(), block.frame_count);
            if (write_result != Error::Ok) {
                callback_error =
                    "WAV write failed with code " +
                    std::to_string(static_cast<int>(write_result)) + ".";
                return;
            }

            if (stats.packets == 0) {
                stats.first_device_position = block.device_position_frames;
                stats.first_qpc_position = block.qpc_position;
            }
            ++stats.packets;
            stats.frames += block.frame_count;
            stats.last_device_position = block.device_position_frames;
            stats.last_qpc_position = block.qpc_position;
            stats.silent_packets += block.silent ? 1U : 0U;
            stats.discontinuities += block.discontinuity ? 1U : 0U;
            stats.event_driven = stats.event_driven && block.event_driven;
            for (const float sample : decoded) {
                stats.peak = std::max(stats.peak, std::abs(sample));
            }
        });
    if (!started) {
        const CaptureError error = capture.last_error();
        std::cerr << "Capture start failed (" << HResultText(error.hresult) << "): "
                  << WideToUtf8(error.message) << "\n";
        return 1;
    }

    std::this_thread::sleep_for(std::chrono::seconds(seconds));
    capture.Stop();
    const CaptureError capture_error = capture.last_error();
    if (FAILED(capture_error.hresult) && callback_error.empty()) {
        callback_error =
            "WASAPI capture failed (" + HResultText(capture_error.hresult) +
            "): " + WideToUtf8(capture_error.message);
    }
    if (!callback_error.empty()) {
        if (writer) {
            writer->Abort();
        }
        std::cerr << callback_error << "\n";
        return 1;
    }
    if (!writer || stats.packets == 0) {
        std::cerr << "Capture completed without receiving a WASAPI packet.\n";
        return 1;
    }
    const Error finalize_result = writer->Finalize();
    if (finalize_result != Error::Ok) {
        std::cerr << "WAV finalize failed with code "
                  << static_cast<int>(finalize_result) << ".\n";
        return 1;
    }

    std::cout << "mode=" << (flow == EndpointFlow::Render ? "system-loopback" : "microphone") << "\n"
              << "output=" << output.u8string() << "\n"
              << "sampleRate=" << format.sample_rate << "\n"
              << "channels=" << format.channels << "\n"
              << "canonical48k=" << (format.sample_rate == 48'000 ? "true" : "false") << "\n"
              << "eventDriven=" << (stats.event_driven ? "true" : "false") << "\n"
              << "packets=" << stats.packets << "\n"
              << "frames=" << stats.frames << "\n"
              << "silentPackets=" << stats.silent_packets << "\n"
              << "discontinuities=" << stats.discontinuities << "\n"
              << "firstDevicePosition=" << stats.first_device_position << "\n"
              << "lastDevicePosition=" << stats.last_device_position << "\n"
              << "firstQpc100ns=" << stats.first_qpc_position << "\n"
              << "lastQpc100ns=" << stats.last_qpc_position << "\n"
              << "peak=" << std::fixed << std::setprecision(6) << stats.peak << "\n";
    return 0;
}

void PrintUsage() {
    std::cerr
        << "Usage:\n"
        << "  Recorder.AudioProbe.exe list\n"
        << "  Recorder.AudioProbe.exe capture-system <seconds> <output.wav> [endpoint-id]\n"
        << "  Recorder.AudioProbe.exe capture-mic <seconds> <output.wav> [endpoint-id]\n";
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
    if (argc == 2 && std::wstring(argv[1]) == L"list") {
        return ListEndpoints();
    }
    if (argc < 4 || argc > 5) {
        PrintUsage();
        return 64;
    }
    const std::wstring command = argv[1];
    EndpointFlow flow;
    if (command == L"capture-system") {
        flow = EndpointFlow::Render;
    } else if (command == L"capture-mic") {
        flow = EndpointFlow::Capture;
    } else {
        PrintUsage();
        return 64;
    }
    std::uint32_t seconds = 0;
    if (!ParsePositiveSeconds(argv[2], &seconds)) {
        std::cerr << "Duration must be an integer from 1 through 300 seconds.\n";
        return 64;
    }
    const std::wstring endpoint_id = argc == 5 ? argv[4] : L"";
    return Capture(flow, seconds, std::filesystem::path(argv[3]), endpoint_id);
}
