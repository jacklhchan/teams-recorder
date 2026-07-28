#pragma once

#include <cstdint>
#include <filesystem>
#include <memory>

namespace recorder::wav {

enum class Error {
    Ok,
    InvalidArgument,
    AlreadyExists,
    IoError,
    InvalidState,
    Overflow,
};

/// Writes IEEE 754 float, little-endian RIFF/WAVE files without platform APIs.
/// Data is written to <final-path>.partial until Finalize succeeds.
class Writer final {
public:
    static std::unique_ptr<Writer> Create(
        const std::filesystem::path& final_path,
        std::uint32_t sample_rate,
        std::uint16_t channels,
        Error* error);

    ~Writer();
    Writer(const Writer&) = delete;
    Writer& operator=(const Writer&) = delete;

    Error WriteFrames(const float* interleaved_frames, std::uint64_t frame_count);
    Error Finalize();

    // Stops writing but deliberately retains the partial file for recovery/inspection.
    void Abort();

    const std::filesystem::path& final_path() const noexcept { return final_path_; }
    const std::filesystem::path& partial_path() const noexcept { return partial_path_; }

private:
    Writer(std::filesystem::path final_path, std::uint32_t sample_rate, std::uint16_t channels);
    Error Open();
    Error WriteHeader(std::uint32_t riff_size, std::uint32_t data_size);

    std::filesystem::path final_path_;
    std::filesystem::path partial_path_;
    std::uint32_t sample_rate_;
    std::uint16_t channels_;
    std::uint16_t block_align_;
    std::uint32_t byte_rate_;
    std::uint32_t data_bytes_ = 0;
    bool finalized_ = false;
    bool aborted_ = false;
    class StreamHolder;
    std::unique_ptr<StreamHolder> stream_;
};

}  // namespace recorder::wav
