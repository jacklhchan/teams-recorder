#pragma once

#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>

namespace recorder::m4a {

enum class Error { Ok, InvalidArgument, AlreadyExists, IoError, InvalidState };

class Writer final {
public:
    static std::unique_ptr<Writer> Create(const std::filesystem::path& final_path,
                                          std::uint32_t bitrate_bps, Error* error,
                                          std::string* detail);
    ~Writer();
    Writer(const Writer&) = delete;
    Writer& operator=(const Writer&) = delete;
    Error WriteFrames(const float* samples, std::uint32_t frames, std::uint64_t start_100ns,
                      std::string* detail);
    Error Finalize(std::string* detail);
    void Abort() noexcept;
private:
    Writer(std::filesystem::path final_path, std::uint32_t bitrate_bps);
    Error Open(std::string* detail);
    std::filesystem::path final_path_, partial_path_;
    std::uint32_t bitrate_bps_;
    bool finalized_ = false, aborted_ = false;
    class Impl;
    std::unique_ptr<Impl> impl_;
};
}
