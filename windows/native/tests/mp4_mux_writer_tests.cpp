#include "mp4_mux_writer.h"
#include "recorder_native_bridge.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <windows.h>
#include <wrl/client.h>

#include <array>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
using Microsoft::WRL::ComPtr;
void Expect(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }

void WritesReopenableH264AacMp4() {
    const auto root = std::filesystem::temp_directory_path() / "teams-recorder-mp4-mux-test";
    std::error_code error;
    std::filesystem::remove_all(root, error);
    std::filesystem::create_directories(root, error);
    Expect(!error, "could not create MP4 test directory");
    const auto output = root / "recording.mp4";
    recorder::mp4::Error create_error{};
    std::string detail;
    auto writer = recorder::mp4::Writer::Create({output, 160, 90, 1'000'000, 128'000, 30}, &create_error, &detail);
    Expect(writer != nullptr && create_error == recorder::mp4::Error::Ok, "could not create MP4 mux writer");
    std::vector<float> audio(960U * 2U, 0.0F);
    std::vector<std::uint8_t> video(160U * 90U * 3U / 2U, static_cast<std::uint8_t>(16U));
    std::fill(video.begin() + 160U * 90U, video.end(), static_cast<std::uint8_t>(128U));
    for (std::uint32_t index = 0; index != 150; ++index) {
        Expect(writer->WriteAudioFrames(audio.data(), 960, static_cast<std::uint64_t>(index) * 200'000U, &detail) == recorder::mp4::Error::Ok,
               "could not write MP4 audio");
    }
    for (std::uint32_t index = 0; index != 30; ++index) {
        video[index % (160U * 90U)] = static_cast<std::uint8_t>(16U + index);
        Expect(writer->WriteVideoNv12(video.data(), 160, static_cast<std::uint64_t>(index) * 333'333U, 333'333U, &detail) == recorder::mp4::Error::Ok,
               "could not write MP4 video");
    }
    Expect(writer->Finalize(&detail) == recorder::mp4::Error::Ok, "could not finalize MP4");
    writer.reset();
    Expect(std::filesystem::exists(output) && std::filesystem::file_size(output) > 0, "MP4 output was not published");
    const auto output_utf8 = output.u8string();
    Expect(recorder_native_validate_h264_aac_mp4(output_utf8.c_str()) == RECORDER_NATIVE_OK,
           "native publication validator could not decode the MP4");

    ComPtr<IMFSourceReader> reader;
    Expect(SUCCEEDED(MFCreateSourceReaderFromURL(output.c_str(), nullptr, &reader)), "published MP4 could not be reopened");
    ComPtr<IMFMediaType> video_type;
    ComPtr<IMFMediaType> audio_type;
    Expect(SUCCEEDED(reader->GetNativeMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, &video_type)), "MP4 video stream missing");
    Expect(SUCCEEDED(reader->GetNativeMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, &audio_type)), "MP4 audio stream missing");
    GUID video_major{};
    GUID audio_major{};
    Expect(SUCCEEDED(video_type->GetGUID(MF_MT_MAJOR_TYPE, &video_major)) && video_major == MFMediaType_Video,
           "MP4 video stream has the wrong media type");
    Expect(SUCCEEDED(audio_type->GetGUID(MF_MT_MAJOR_TYPE, &audio_major)) && audio_major == MFMediaType_Audio,
           "MP4 audio stream has the wrong media type");

    ComPtr<IMFMediaType> decoded_video;
    Expect(SUCCEEDED(MFCreateMediaType(&decoded_video)) &&
           SUCCEEDED(decoded_video->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video)) &&
           SUCCEEDED(decoded_video->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12)) &&
           SUCCEEDED(reader->SetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr, decoded_video.Get())),
           "MP4 video stream could not be configured for decode");
    ComPtr<IMFSample> video_sample;
    DWORD stream_flags = 0;
    Expect(SUCCEEDED(reader->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, nullptr,
                                        &stream_flags, nullptr, &video_sample)) && video_sample != nullptr,
           "MP4 video stream did not decode a sample");

    ComPtr<IMFMediaType> decoded_audio;
    Expect(SUCCEEDED(MFCreateMediaType(&decoded_audio)) &&
           SUCCEEDED(decoded_audio->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio)) &&
           SUCCEEDED(decoded_audio->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM)) &&
           SUCCEEDED(reader->SetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr, decoded_audio.Get())),
           "MP4 audio stream could not be configured for decode");
    ComPtr<IMFSample> audio_sample;
    Expect(SUCCEEDED(reader->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, nullptr,
                                        &stream_flags, nullptr, &audio_sample)) && audio_sample != nullptr,
           "MP4 audio stream did not decode a sample");
    std::filesystem::remove_all(root, error);
}
}

int main() {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(com) && com != RPC_E_CHANGED_MODE) return 1;
    const HRESULT mf = MFStartup(MF_VERSION);
    try { if (FAILED(mf)) throw std::runtime_error("MFStartup failed"); WritesReopenableH264AacMp4(); }
    catch (const std::exception& exception) { std::cerr << "FAIL " << exception.what() << '\n'; if (SUCCEEDED(mf)) MFShutdown(); if (SUCCEEDED(com)) CoUninitialize(); return 1; }
    if (SUCCEEDED(mf)) MFShutdown();
    if (SUCCEEDED(com)) CoUninitialize();
    std::cout << "PASS MP4 mux writer\n";
    return 0;
}
