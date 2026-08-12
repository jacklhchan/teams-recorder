#pragma once

#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

namespace recorder::media {

enum class CheckpointStage {
    AfterEndOfSegment,
    AfterAllStreamMarkers,
    BeforeByteStreamFlush,
    BeforeFileFlush,
};

using CheckpointFaultHook = HRESULT (*)(CheckpointStage stage);

// Native-test seam. Production leaves this null. A failing HRESULT aborts the
// checkpoint before its sequence can advance.
void SetCheckpointFaultHookForTesting(CheckpointFaultHook hook) noexcept;

struct DurableCheckpoint {
    std::uint64_t sequence = 0;
    std::uint64_t file_size_bytes = 0;
};

// Owns the Media Foundation fragmented-MP4 sink and the byte stream on which
// it writes.  A checkpoint is not reported until all pre-marker samples have
// traversed the sink writer, the MF byte stream has been flushed, and Windows
// has acknowledged FlushFileBuffers for the same file.
class FragmentedMp4Sink final {
public:
    static std::unique_ptr<FragmentedMp4Sink> Create(
        const std::filesystem::path& path,
        IMFMediaType* video_output_type,
        IMFMediaType* audio_output_type,
        std::string* detail);

    ~FragmentedMp4Sink();
    FragmentedMp4Sink(const FragmentedMp4Sink&) = delete;
    FragmentedMp4Sink& operator=(const FragmentedMp4Sink&) = delete;

    HRESULT SetInputMediaType(DWORD stream_index, IMFMediaType* input_type);
    HRESULT BeginWriting();
    HRESULT WriteSample(DWORD stream_index, IMFSample* sample);

    HRESULT CreateDurableCheckpoint(
        const std::vector<DWORD>& stream_indices,
        DurableCheckpoint* checkpoint,
        std::string* detail);
    HRESULT Finalize(std::string* detail);

    void Close() noexcept;
    bool begun_writing() const noexcept { return begun_writing_; }

private:
    FragmentedMp4Sink() = default;
    HRESULT Open(
        const std::filesystem::path& path,
        IMFMediaType* video_output_type,
        IMFMediaType* audio_output_type,
        std::string* detail);
    HRESULT FlushDurably(std::uint64_t* file_size_bytes, bool allow_fault_hook,
                         std::string* detail);

    class Callback;
    class FileStream;
    Microsoft::WRL::ComPtr<Callback> callback_;
    Microsoft::WRL::ComPtr<FileStream> file_stream_;
    Microsoft::WRL::ComPtr<IMFByteStream> byte_stream_;
    Microsoft::WRL::ComPtr<IMFMediaSink> media_sink_;
    Microsoft::WRL::ComPtr<IMFSinkWriter> sink_writer_;
    std::uint64_t next_marker_id_ = 1;
    std::uint64_t checkpoint_sequence_ = 0;
    bool begun_writing_ = false;
    bool finalized_ = false;
};

}  // namespace recorder::media
