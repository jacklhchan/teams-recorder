#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>

namespace recorder::mp4 {

enum class Error { Ok, InvalidArgument, AlreadyExists, IoError, InvalidState };

struct VideoFormat final {
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t frames_per_second = 0;
    std::uint32_t bitrate_bps = 0;
};

// An optional A/V artifact writer. It owns a separate .partial file and is
// deliberately independent from the audio-only M4A writer.
class AvWriter final {
public:
    static std::unique_ptr<AvWriter> Create(const std::filesystem::path& final_path,
                                            VideoFormat video,
                                            std::uint32_t audio_bitrate_bps,
                                            Error* error, std::string* detail);
    ~AvWriter();
    AvWriter(const AvWriter&) = delete;
    AvWriter& operator=(const AvWriter&) = delete;

    // `bgra` is tightly packed BGRA/RGB32, exactly width*height*4 bytes.
    Error WriteVideoFrame(const std::uint8_t* bgra, std::size_t byte_count,
                          std::uint64_t start_100ns, std::uint64_t duration_100ns,
                          std::string* detail);
    Error WriteAudioBlock(const float* samples, std::uint32_t frames,
                          std::uint64_t start_100ns, std::string* detail);
    Error Finalize(std::string* detail);
    // Best effort close that retains .partial evidence if close/publish fails.
    Error FinalizeForRecovery(std::string* detail);
    void Abort() noexcept;

private:
    AvWriter(std::filesystem::path final_path, VideoFormat video,
             std::uint32_t audio_bitrate_bps);
    Error Open(std::string* detail);
    Error WriteAudioAccessUnit(const float* samples, std::uint64_t start_100ns,
                               std::uint64_t duration_100ns, std::string* detail);
    Error DrainAudio(std::string* detail);

    std::filesystem::path final_path_, partial_path_;
    VideoFormat video_;
    std::uint32_t audio_bitrate_bps_;
    bool finalized_ = false;
    bool aborted_ = false;
    bool preserve_partial_ = false;
    class Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace recorder::mp4
