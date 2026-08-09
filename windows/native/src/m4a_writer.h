#pragma once

#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>

namespace recorder::m4a {

enum class Error { Ok, InvalidArgument, AlreadyExists, IoError, InvalidState };

struct DurableCheckpoint {
    std::uint64_t sequence = 0;
    std::uint64_t file_size_bytes = 0;
    std::uint64_t media_time_100ns = 0;
};

class Writer final {
public:
    static std::unique_ptr<Writer> Create(const std::filesystem::path& final_path,
                                          std::uint32_t bitrate_bps, Error* error,
                                          std::string* detail);
    // Creates an audio-only fragmented-MP4 safety writer at the exact path.
    // Finalize durably closes the sink but does not rename; the managed
    // session store owns publication of this canonical work file.
    static std::unique_ptr<Writer> CreateWorkFile(
        const std::filesystem::path& work_path,
        std::uint32_t bitrate_bps, Error* error, std::string* detail);
    ~Writer();
    Writer(const Writer&) = delete;
    Writer& operator=(const Writer&) = delete;
    Error WriteFrames(const float* samples, std::uint32_t frames, std::uint64_t start_100ns,
                      std::string* detail);
    Error CreateDurableCheckpoint(std::uint64_t media_time_100ns,
                                  DurableCheckpoint* checkpoint,
                                  std::string* detail);
    Error Finalize(std::string* detail);
    // Used by capture-fault paths.  Unlike Abort(), this makes one best-effort
    // attempt to close the AAC container and retains the .partial work file if
    // close or publish cannot complete.  The caller can then recover a valid
    // backup on the next startup, or retain the partial as evidence.
    Error FinalizeForRecovery(std::string* detail);
    void Abort() noexcept;
private:
    Writer(std::filesystem::path final_path, std::uint32_t bitrate_bps,
           bool publish_on_finalize);
    Error Open(std::string* detail);
    Error WriteCanonicalBlock(const float* samples, std::uint64_t start_100ns,
                              std::uint64_t duration_100ns, std::string* detail);
    Error DrainToMinimumAacBlocks(std::string* detail);
    std::filesystem::path final_path_, partial_path_;
    std::uint32_t bitrate_bps_;
    bool publish_on_finalize_ = true;
    bool finalized_ = false, aborted_ = false, preserve_partial_ = false;
    class Impl;
    std::unique_ptr<Impl> impl_;
};
}
