#include "mp4_av_writer.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cmath>
#include <chrono>
#include <cstdio>
#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>
#include <windows.h>

namespace {
using Microsoft::WRL::ComPtr;
using recorder::mp4::AvWriter;
using recorder::mp4::Error;
using recorder::mp4::VideoFormat;

class Runtime final {
public:
    Runtime() {
        if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) ||
            FAILED(MFStartup(MF_VERSION, MFSTARTUP_FULL))) {
            throw std::runtime_error("could not initialize Media Foundation");
        }
    }
    ~Runtime() { MFShutdown(); CoUninitialize(); }
};

void Expect(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

std::filesystem::path Directory() {
    const auto path = std::filesystem::temp_directory_path() /
        ("teams-recorder-mp4-av-writer-" + std::to_string(GetCurrentProcessId()));
    std::error_code error;
    std::filesystem::remove_all(path, error);
    std::filesystem::create_directories(path, error);
    if (error) throw std::runtime_error("could not create test directory");
    return path;
}

void WriteSynthetic(AvWriter* writer) {
    constexpr std::uint32_t width = 64U;
    constexpr std::uint32_t height = 48U;
    std::vector<std::uint8_t> frame(width * height * 4U, 0U);
    std::vector<float> audio(960U * 2U, 0.0F);
    std::string detail;
    for (std::uint32_t index = 0; index < 12U; ++index) {
        for (std::size_t pixel = 0; pixel < frame.size(); pixel += 4U) {
            frame[pixel] = static_cast<std::uint8_t>(index * 13U);
            frame[pixel + 1U] = static_cast<std::uint8_t>(255U - index * 13U);
            frame[pixel + 2U] = 80U;
            frame[pixel + 3U] = 255U;
        }
        Expect(writer->WriteVideoFrame(frame.data(), frame.size(),
            static_cast<std::uint64_t>(index) * 333'333ULL, 333'333ULL, &detail) == Error::Ok,
            "could not write synthetic video frame");
        for (std::size_t sample = 0; sample < audio.size(); ++sample) {
            audio[sample] = 0.2F * std::sin(static_cast<float>(index * audio.size() + sample) * 0.01F);
        }
        Expect(writer->WriteAudioBlock(audio.data(), 960U,
            static_cast<std::uint64_t>(index) * 200'000ULL, &detail) == Error::Ok,
            "could not write synthetic audio block");
    }
}

void ExpectStreams(const std::filesystem::path& path) {
    ComPtr<IMFSourceReader> reader;
    HRESULT result = MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader);
    Expect(SUCCEEDED(result) && reader != nullptr, "could not open finalized MP4");
    ComPtr<IMFMediaType> video;
    constexpr DWORD video_stream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
    result = reader->GetNativeMediaType(video_stream, 0U, &video);
    GUID subtype = GUID_NULL;
    Expect(SUCCEEDED(result) && video != nullptr &&
        SUCCEEDED(video->GetGUID(MF_MT_SUBTYPE, &subtype)) && subtype == MFVideoFormat_H264,
        "MP4 has no H.264 video stream");
    constexpr DWORD audio_stream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
    ComPtr<IMFMediaType> audio;
    result = reader->GetNativeMediaType(audio_stream, 0U, &audio);
    Expect(SUCCEEDED(result) && audio != nullptr &&
        SUCCEEDED(audio->GetGUID(MF_MT_SUBTYPE, &subtype)) && subtype == MFAudioFormat_AAC,
        "MP4 has no AAC audio stream");
}

void FinalizesSyntheticMp4(const std::filesystem::path& directory) {
    const auto path = directory / "synthetic.mp4";
    Error error = Error::Ok;
    std::string detail;
    auto writer = AvWriter::Create(path, {64U, 48U, 30U, 500'000U}, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok, "could not create MP4 A/V writer");
    WriteSynthetic(writer.get());
    Expect(writer->Finalize(&detail) == Error::Ok, "could not finalize synthetic MP4");
    Expect(std::filesystem::exists(path) && !std::filesystem::exists(path.wstring() + L".partial"),
           "MP4 publish contract failed");
    writer.reset();
    ExpectStreams(path);
}

void RecoveryFinalizesOrRetainsPartial(const std::filesystem::path& directory) {
    const auto path = directory / "recovery.mp4";
    Error error = Error::Ok;
    std::string detail;
    auto writer = AvWriter::Create(path, {64U, 48U, 30U, 500'000U}, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok, "could not create recovery MP4 writer");
    WriteSynthetic(writer.get());
    const Error final = writer->FinalizeForRecovery(&detail);
    Expect(final == Error::Ok || std::filesystem::exists(path.wstring() + L".partial"),
           "recovery path discarded its partial evidence");
}

void StaticVideoKeepsUpWithFiveSecondAudio(const std::filesystem::path& directory) {
    const auto path = directory / "static-five-seconds.mp4";
    Error error = Error::Ok;
    std::string detail;
    auto writer = AvWriter::Create(path, {64U, 48U, 30U, 500'000U}, 128'000U, &error, &detail);
    Expect(writer != nullptr && error == Error::Ok, "could not create static MP4 writer");
    std::vector<std::uint8_t> frame(64U * 48U * 4U, 80U);
    std::vector<float> audio(960U * 2U, 0.0F);
    std::uint64_t video_time = 0;
    constexpr std::uint64_t video_duration = 333'333U;
    for (std::uint32_t block = 0; block < 250U; ++block) {
        const std::uint64_t audio_time = static_cast<std::uint64_t>(block) * 200'000U;
        while (video_time <= audio_time) {
            Expect(writer->WriteVideoFrame(frame.data(), frame.size(), video_time, video_duration, &detail) == Error::Ok,
                   "could not duplicate static video frame");
            video_time += video_duration;
        }
        Expect(writer->WriteAudioBlock(audio.data(), 960U, audio_time, &detail) == Error::Ok,
               "could not write static-video audio");
    }
    const auto started = std::chrono::steady_clock::now();
    Expect(writer->Finalize(&detail) == Error::Ok, "could not finalize static five-second MP4");
    const auto elapsed = std::chrono::steady_clock::now() - started;
    Expect(elapsed < std::chrono::seconds(10), "static MP4 finalization was unexpectedly throttled");
    ExpectStreams(path);
}
}  // namespace

int main() {
    try {
        Runtime runtime;
        const auto directory = Directory();
        FinalizesSyntheticMp4(directory);
        RecoveryFinalizesOrRetainsPartial(directory);
        StaticVideoKeepsUpWithFiveSecondAudio(directory);
        return 0;
    } catch (const std::exception& error) {
        OutputDebugStringA(error.what());
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
}
