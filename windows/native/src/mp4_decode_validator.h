#pragma once

#include <cstdint>
#include <filesystem>
#include <string>

namespace recorder::mp4::validation {

// This is intentionally a narrow publication gate, not a media analyser.  It
// proves that a finalized local MP4 exposes H.264 and AAC source streams and
// that Media Foundation can decode a non-empty sample from each.  Callers may
// use it before promoting an MP4 over the independent M4A safety recording.
enum class Error {
    Ok,
    InvalidArgument,
    FileNotFound,
    RuntimeInitializationFailed,
    SourceReaderFailed,
    MissingH264Video,
    MissingAacAudio,
    VideoDecodeFailed,
    AudioDecodeFailed,
};

struct Report {
    std::uint64_t decoded_video_samples = 0;
    std::uint64_t decoded_audio_samples = 0;
};

Error ProbeDecodableH264AacMp4(const std::filesystem::path& path,
                               Report* report,
                               std::string* detail) noexcept;

// The independent M4A safety recording is only publishable when the AAC
// stream can be decoded. This is intentionally separate from the MP4 probe:
// a video encoder fault must not make an otherwise valid audio fallback fail.
Error ProbeDecodableAacM4a(const std::filesystem::path& path,
                           Report* report,
                           std::string* detail) noexcept;

}  // namespace recorder::mp4::validation
