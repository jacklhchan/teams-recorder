#include "wav_writer.h"

#include <array>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <iostream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

using recorder::wav::Error;
using recorder::wav::Writer;

struct ParsedWave {
    std::uint32_t riff_size;
    std::uint16_t format;
    std::uint16_t channels;
    std::uint32_t sample_rate;
    std::uint32_t byte_rate;
    std::uint16_t block_align;
    std::uint16_t bits_per_sample;
    std::uint32_t data_size;
    std::vector<unsigned char> data;
};

std::uint16_t ReadU16(const std::vector<unsigned char>& bytes, std::size_t offset) {
    return static_cast<std::uint16_t>(bytes.at(offset)) |
        (static_cast<std::uint16_t>(bytes.at(offset + 1)) << 8U);
}

std::uint32_t ReadU32(const std::vector<unsigned char>& bytes, std::size_t offset) {
    std::uint32_t result = 0;
    for (std::size_t index = 0; index != 4; ++index) result |= static_cast<std::uint32_t>(bytes.at(offset + index)) << (index * 8U);
    return result;
}

ParsedWave ParseWave(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    const std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(input)), {});
    if (bytes.size() < 44 || std::string(bytes.begin(), bytes.begin() + 4) != "RIFF" ||
        std::string(bytes.begin() + 8, bytes.begin() + 12) != "WAVE" ||
        std::string(bytes.begin() + 12, bytes.begin() + 16) != "fmt " ||
        std::string(bytes.begin() + 36, bytes.begin() + 40) != "data") {
        throw std::runtime_error("not a canonical WAV file");
    }
    const auto data_size = ReadU32(bytes, 40);
    if (bytes.size() != 44U + data_size) throw std::runtime_error("size fields do not match file length");
    return {ReadU32(bytes, 4), ReadU16(bytes, 20), ReadU16(bytes, 22), ReadU32(bytes, 24),
            ReadU32(bytes, 28), ReadU16(bytes, 32), ReadU16(bytes, 34), data_size,
            std::vector<unsigned char>(bytes.begin() + 44, bytes.end())};
}

void Expect(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

std::filesystem::path NewTestDirectory(const char* name) {
    const auto path = std::filesystem::temp_directory_path() / (std::string("recorder-wav-") + name);
    std::error_code ec;
    std::filesystem::remove_all(path, ec);
    std::filesystem::create_directories(path);
    return path;
}

void HeaderAndDataAreCanonicalFloatWave() {
    const auto folder = NewTestDirectory("header");
    const auto final_path = folder / "capture.wav";
    Error error = Error::Ok;
    auto writer = Writer::Create(final_path, 48'000, 2, &error);
    Expect(writer != nullptr && error == Error::Ok, "writer create failed");
    const std::array<float, 4> frames = {0.0F, 1.0F, -1.0F, 0.5F};
    Expect(writer->WriteFrames(frames.data(), 2) == Error::Ok, "write failed");
    Expect(writer->Finalize() == Error::Ok, "finalize failed");

    const auto wave = ParseWave(final_path);
    Expect(wave.riff_size == 52 && wave.format == 3 && wave.channels == 2 && wave.sample_rate == 48'000,
           "RIFF or format fields are wrong");
    Expect(wave.byte_rate == 384'000 && wave.block_align == 8 && wave.bits_per_sample == 32 && wave.data_size == 16,
           "PCM layout fields are wrong");
    Expect(ReadU32(wave.data, 4) == 0x3f800000U && ReadU32(wave.data, 8) == 0xbf800000U &&
           ReadU32(wave.data, 12) == 0x3f000000U, "float samples are not IEEE little-endian");
    std::filesystem::remove_all(folder);
}

void FinalizeOnlySucceedsOnce() {
    const auto folder = NewTestDirectory("finalize-once");
    Error error = Error::Ok;
    auto writer = Writer::Create(folder / "capture.wav", 44'100, 1, &error);
    Expect(writer->Finalize() == Error::Ok, "first finalize failed");
    Expect(writer->Finalize() == Error::InvalidState, "second finalize must fail");
    std::filesystem::remove_all(folder);
}

void ExistingFinalIsNeverReplaced() {
    const auto folder = NewTestDirectory("existing-final");
    const auto final_path = folder / "capture.wav";
    { std::ofstream output(final_path, std::ios::binary); output << "original"; }
    Error error = Error::Ok;
    auto writer = Writer::Create(final_path, 44'100, 1, &error);
    Expect(writer == nullptr && error == Error::AlreadyExists, "existing final was accepted");
    std::string contents;
    {
        std::ifstream input(final_path, std::ios::binary);
        contents.assign(std::istreambuf_iterator<char>(input), {});
    }
    Expect(contents == "original", "existing final was modified");
    std::filesystem::remove_all(folder);
}

void FinalAppearingBeforeFinalizeIsNeverReplaced() {
    const auto folder = NewTestDirectory("late-final");
    const auto final_path = folder / "capture.wav";
    Error error = Error::Ok;
    auto writer = Writer::Create(final_path, 44'100, 1, &error);
    { std::ofstream output(final_path, std::ios::binary); output << "newer"; }
    Expect(writer->Finalize() == Error::AlreadyExists, "late existing final was accepted");
    std::string contents;
    {
        std::ifstream input(final_path, std::ios::binary);
        contents.assign(std::istreambuf_iterator<char>(input), {});
    }
    Expect(contents == "newer" && std::filesystem::exists(writer->partial_path()), "late final was modified or partial lost");
    std::filesystem::remove_all(folder);
}

void AbortPreservesPartial() {
    const auto folder = NewTestDirectory("abort");
    const auto final_path = folder / "capture.wav";
    Error error = Error::Ok;
    auto writer = Writer::Create(final_path, 44'100, 1, &error);
    const float frame = 0.25F;
    Expect(writer->WriteFrames(&frame, 1) == Error::Ok, "write failed");
    const auto partial_path = writer->partial_path();
    writer->Abort();
    Expect(std::filesystem::exists(partial_path) && !std::filesystem::exists(final_path), "abort did not retain partial");
    Expect(writer->WriteFrames(&frame, 1) == Error::InvalidState && writer->Finalize() == Error::InvalidState,
           "aborted writer accepted an operation");
    std::filesystem::remove_all(folder);
}

void BadArgumentsAndOverflowAreRejected() {
    Error error = Error::Ok;
    Expect(Writer::Create({}, 44'100, 1, &error) == nullptr && error == Error::InvalidArgument, "empty path accepted");
    Expect(Writer::Create("x.wav", 0, 1, &error) == nullptr && error == Error::InvalidArgument, "zero sample rate accepted");
    Expect(Writer::Create("x.wav", 44'100, 0, &error) == nullptr && error == Error::InvalidArgument, "zero channels accepted");
    const auto folder = NewTestDirectory("bad-frames");
    auto writer = Writer::Create(folder / "capture.wav", 44'100, 2, &error);
    Expect(writer->WriteFrames(nullptr, 1) == Error::InvalidArgument, "null frames accepted");
    Expect(writer->WriteFrames(reinterpret_cast<const float*>(1), UINT64_MAX) == Error::Overflow, "overflowing frames accepted");
    writer->Abort();
    std::filesystem::remove_all(folder);
}

}  // namespace

int main() {
    const std::array<std::pair<const char*, void (*)()>, 6> tests = {{{"header", HeaderAndDataAreCanonicalFloatWave},
        {"finalize once", FinalizeOnlySucceedsOnce}, {"no replacement", ExistingFinalIsNeverReplaced},
        {"late final no replacement", FinalAppearingBeforeFinalizeIsNeverReplaced}, {"abort", AbortPreservesPartial},
        {"bad arguments", BadArgumentsAndOverflowAreRejected}}};
    try {
        for (const auto& test : tests) { test.second(); std::cout << "PASS " << test.first << '\n'; }
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
    return 0;
}
