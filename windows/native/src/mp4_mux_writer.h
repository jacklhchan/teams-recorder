#pragma once

#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>

namespace recorder::mp4 {

enum class Error { Ok, InvalidArgument, AlreadyExists, IoError, InvalidState };

struct Config {
    std::filesystem::path final_path;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t video_bitrate_bps = 0;
    std::uint32_t audio_bitrate_bps = 128'000;
    std::uint32_t frame_rate = 30;
};

// A native-only H.264/AAC MPEG-4 writer.  It accepts canonical 48 kHz stereo
// PCM plus already-converted NV12 video; WGC BGRA conversion deliberately
// remains outside this class.  Final output is published only after the sink
// finalizes and its .partial path can be atomically renamed.
class Writer final {
public:
    static std::unique_ptr<Writer> Create(const Config& config, Error* error,
                                          std::string* detail);
    ~Writer();
    Writer(const Writer&) = delete;
    Writer& operator=(const Writer&) = delete;

    Error WriteAudioFrames(const float* samples, std::uint32_t frames,
                           std::uint64_t start_100ns, std::string* detail);
    Error WriteVideoNv12(const std::uint8_t* bytes, std::uint32_t stride,
                         std::uint64_t timestamp_100ns,
                         std::uint64_t duration_100ns, std::string* detail);
    Error Finalize(std::string* detail);
    void Abort() noexcept;

private:
    explicit Writer(Config config);
    Error Open(std::string* detail);
    Error WriteAudioBlock(const float* samples, std::uint64_t timestamp_100ns,
                          std::uint64_t duration_100ns, std::string* detail);
    Error DrainAudio(std::string* detail);

    Config config_;
    std::filesystem::path partial_path_;
    bool finalized_ = false;
    bool aborted_ = false;
    class Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace recorder::mp4
