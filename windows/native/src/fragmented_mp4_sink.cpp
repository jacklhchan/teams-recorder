#include "fragmented_mp4_sink.h"

#include <mfapi.h>
#include <mferror.h>
#include <windows.h>
#include <wrl/implements.h>

#include <chrono>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <limits>
#include <mutex>
#include <unordered_set>

namespace recorder::media {
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::ClassicCom;

namespace {
constexpr auto kMarkerTimeout = std::chrono::seconds(15);
constexpr auto kFinalizeTimeout = std::chrono::seconds(30);
constexpr std::uint64_t kMinimumFragmentDuration100ns = 20'000'000;  // 2 s.
std::atomic<CheckpointFaultHook> g_checkpoint_fault_hook{nullptr};

HRESULT Fail(HRESULT hr, std::string* detail, const char* message) {
    if (detail != nullptr) {
        *detail = message;
    }
    return hr;
}

HRESULT InjectCheckpointFault(CheckpointStage stage) noexcept {
    const auto hook = g_checkpoint_fault_hook.load(std::memory_order_acquire);
    return hook == nullptr ? S_OK : hook(stage);
}

HRESULT ResolveAacOutputType(
    IMFMediaType* requested,
    ComPtr<IMFMediaType>* resolved) {
    if (requested == nullptr || resolved == nullptr) return E_INVALIDARG;
    GUID subtype{};
    HRESULT hr = requested->GetGUID(MF_MT_SUBTYPE, &subtype);
    if (FAILED(hr) || subtype != MFAudioFormat_AAC) return E_INVALIDARG;
    UINT32 requested_rate = 0;
    UINT32 requested_channels = 0;
    UINT32 requested_bytes_per_second = 0;
    if (SUCCEEDED(hr)) hr = requested->GetUINT32(
        MF_MT_AUDIO_SAMPLES_PER_SECOND, &requested_rate);
    if (SUCCEEDED(hr)) hr = requested->GetUINT32(
        MF_MT_AUDIO_NUM_CHANNELS, &requested_channels);
    if (SUCCEEDED(hr)) hr = requested->GetUINT32(
        MF_MT_AUDIO_AVG_BYTES_PER_SECOND, &requested_bytes_per_second);
    if (FAILED(hr)) return hr;

    ComPtr<IMFCollection> available;
    hr = MFTranscodeGetAudioOutputAvailableTypes(
        MFAudioFormat_AAC, MFT_ENUM_FLAG_ALL, nullptr, &available);
    DWORD count = 0;
    if (SUCCEEDED(hr)) hr = available->GetElementCount(&count);
    for (DWORD index = 0; SUCCEEDED(hr) && index < count; ++index) {
        ComPtr<IUnknown> unknown;
        hr = available->GetElement(index, &unknown);
        ComPtr<IMFMediaType> candidate;
        if (SUCCEEDED(hr)) hr = unknown.As(&candidate);
        UINT32 rate = 0;
        UINT32 channels = 0;
        UINT32 bytes_per_second = 0;
        if (SUCCEEDED(hr)) hr = candidate->GetUINT32(
            MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
        if (SUCCEEDED(hr)) hr = candidate->GetUINT32(
            MF_MT_AUDIO_NUM_CHANNELS, &channels);
        if (SUCCEEDED(hr)) hr = candidate->GetUINT32(
            MF_MT_AUDIO_AVG_BYTES_PER_SECOND, &bytes_per_second);
        if (SUCCEEDED(hr) && rate == requested_rate &&
            channels == requested_channels &&
            bytes_per_second == requested_bytes_per_second) {
            *resolved = std::move(candidate);
            return S_OK;
        }
    }
    return MF_E_TOPO_CODEC_NOT_FOUND;
}
}  // namespace

void SetCheckpointFaultHookForTesting(CheckpointFaultHook hook) noexcept {
    g_checkpoint_fault_hook.store(hook, std::memory_order_release);
}

class FragmentedMp4Sink::FileStream final
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IStream> {
public:
    explicit FileStream(HANDLE handle) : handle_(handle) {}

    ~FileStream() override {
        if (handle_ != INVALID_HANDLE_VALUE) {
            CloseHandle(handle_);
        }
    }

    IFACEMETHODIMP Read(void* destination, ULONG count, ULONG* read) override {
        if (destination == nullptr && count != 0) return STG_E_INVALIDPOINTER;
        std::lock_guard<std::mutex> lock(mutex_);
        DWORD actual = 0;
        if (!ReadFile(handle_, destination, count, &actual, nullptr)) {
            return HRESULT_FROM_WIN32(GetLastError());
        }
        if (read != nullptr) *read = actual;
        return actual == count ? S_OK : S_FALSE;
    }

    IFACEMETHODIMP Write(const void* source, ULONG count, ULONG* written) override {
        if (source == nullptr && count != 0) return STG_E_INVALIDPOINTER;
        std::lock_guard<std::mutex> lock(mutex_);
        DWORD actual = 0;
        if (!WriteFile(handle_, source, count, &actual, nullptr)) {
            return HRESULT_FROM_WIN32(GetLastError());
        }
        if (written != nullptr) *written = actual;
        return actual == count ? S_OK : STG_E_MEDIUMFULL;
    }

    IFACEMETHODIMP Seek(
        LARGE_INTEGER move, DWORD origin, ULARGE_INTEGER* new_position) override {
        if (origin != STREAM_SEEK_SET && origin != STREAM_SEEK_CUR &&
            origin != STREAM_SEEK_END) {
            return STG_E_INVALIDFUNCTION;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        LARGE_INTEGER position{};
        if (!SetFilePointerEx(handle_, move, &position, origin)) {
            return HRESULT_FROM_WIN32(GetLastError());
        }
        if (position.QuadPart < 0) return STG_E_SEEKERROR;
        if (new_position != nullptr) {
            new_position->QuadPart = static_cast<ULONGLONG>(position.QuadPart);
        }
        return S_OK;
    }

    IFACEMETHODIMP SetSize(ULARGE_INTEGER new_size) override {
        if (new_size.QuadPart > static_cast<ULONGLONG>(
                (std::numeric_limits<LONGLONG>::max)())) {
            return STG_E_INVALIDFUNCTION;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        LARGE_INTEGER original{};
        LARGE_INTEGER zero{};
        if (!SetFilePointerEx(handle_, zero, &original, FILE_CURRENT)) {
            return HRESULT_FROM_WIN32(GetLastError());
        }
        LARGE_INTEGER requested{};
        requested.QuadPart = static_cast<LONGLONG>(new_size.QuadPart);
        if (!SetFilePointerEx(handle_, requested, nullptr, FILE_BEGIN) ||
            !SetEndOfFile(handle_)) {
            return HRESULT_FROM_WIN32(GetLastError());
        }
        if (!SetFilePointerEx(handle_, original, nullptr, FILE_BEGIN)) {
            return HRESULT_FROM_WIN32(GetLastError());
        }
        return S_OK;
    }

    IFACEMETHODIMP CopyTo(
        IStream*, ULARGE_INTEGER, ULARGE_INTEGER*, ULARGE_INTEGER*) override {
        return E_NOTIMPL;
    }

    IFACEMETHODIMP Commit(DWORD) override {
        return FlushHandle();
    }

    IFACEMETHODIMP Revert() override { return STG_E_REVERTED; }
    IFACEMETHODIMP LockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override {
        return STG_E_INVALIDFUNCTION;
    }
    IFACEMETHODIMP UnlockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override {
        return STG_E_INVALIDFUNCTION;
    }

    IFACEMETHODIMP Stat(STATSTG* stat, DWORD flags) override {
        if (stat == nullptr) return STG_E_INVALIDPOINTER;
        std::memset(stat, 0, sizeof(*stat));
        stat->type = STGTY_STREAM;
        stat->grfMode = STGM_READWRITE | STGM_SHARE_DENY_NONE;
        std::uint64_t size = 0;
        const HRESULT hr = Size(&size);
        if (FAILED(hr)) return hr;
        stat->cbSize.QuadPart = size;
        if ((flags & STATFLAG_NONAME) == 0) stat->pwcsName = nullptr;
        return S_OK;
    }

    IFACEMETHODIMP Clone(IStream**) override { return E_NOTIMPL; }

    HRESULT FlushHandle() {
        std::lock_guard<std::mutex> lock(mutex_);
        return FlushFileBuffers(handle_)
            ? S_OK : HRESULT_FROM_WIN32(GetLastError());
    }

    HRESULT Size(std::uint64_t* size) {
        if (size == nullptr) return E_POINTER;
        std::lock_guard<std::mutex> lock(mutex_);
        LARGE_INTEGER file_size{};
        if (!GetFileSizeEx(handle_, &file_size) || file_size.QuadPart < 0) {
            return HRESULT_FROM_WIN32(GetLastError());
        }
        *size = static_cast<std::uint64_t>(file_size.QuadPart);
        return S_OK;
    }

private:
    HANDLE handle_ = INVALID_HANDLE_VALUE;
    std::mutex mutex_;
};

class FragmentedMp4Sink::Callback final
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IMFSinkWriterCallback> {
public:
    IFACEMETHODIMP OnFinalize(HRESULT status) override {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            finalize_status_ = status;
            finalize_completed_ = true;
        }
        condition_.notify_all();
        return S_OK;
    }

    IFACEMETHODIMP OnMarker(DWORD, LPVOID context) override {
        const auto marker = static_cast<std::uint64_t>(
            reinterpret_cast<std::uintptr_t>(context));
        {
            std::lock_guard<std::mutex> lock(mutex_);
            completed_markers_.insert(marker);
        }
        condition_.notify_all();
        return S_OK;
    }

    bool WaitForMarkers(const std::vector<std::uint64_t>& markers) {
        std::unique_lock<std::mutex> lock(mutex_);
        const bool completed = condition_.wait_for(lock, kMarkerTimeout, [&] {
            for (const auto marker : markers) {
                if (completed_markers_.find(marker) == completed_markers_.end()) {
                    return false;
                }
            }
            return true;
        });
        if (completed) {
            for (const auto marker : markers) completed_markers_.erase(marker);
        }
        return completed;
    }

    void PrepareForFinalize() {
        std::lock_guard<std::mutex> lock(mutex_);
        finalize_completed_ = false;
        finalize_status_ = E_PENDING;
    }

    HRESULT WaitForFinalize() {
        std::unique_lock<std::mutex> lock(mutex_);
        if (!condition_.wait_for(lock, kFinalizeTimeout, [&] {
                return finalize_completed_;
            })) {
            return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        }
        return finalize_status_;
    }

private:
    std::mutex mutex_;
    std::condition_variable condition_;
    std::unordered_set<std::uint64_t> completed_markers_;
    HRESULT finalize_status_ = E_PENDING;
    bool finalize_completed_ = false;
};

std::unique_ptr<FragmentedMp4Sink> FragmentedMp4Sink::Create(
    const std::filesystem::path& path,
    IMFMediaType* video_output_type,
    IMFMediaType* audio_output_type,
    std::string* detail) {
    auto result = std::unique_ptr<FragmentedMp4Sink>(new FragmentedMp4Sink());
    if (FAILED(result->Open(path, video_output_type, audio_output_type, detail))) {
        return nullptr;
    }
    return result;
}

FragmentedMp4Sink::~FragmentedMp4Sink() {
    Close();
}

HRESULT FragmentedMp4Sink::Open(
    const std::filesystem::path& path,
    IMFMediaType* video_output_type,
    IMFMediaType* audio_output_type,
    std::string* detail) {
    if (path.empty() || (video_output_type == nullptr && audio_output_type == nullptr)) {
        return Fail(E_INVALIDARG, detail, "A fragmented MP4 path and at least one stream are required.");
    }

    const HANDLE handle = CreateFileW(
        path.c_str(),
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL,
        nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
        return Fail(HRESULT_FROM_WIN32(GetLastError()), detail,
                    "Creating the fragmented MP4 work file failed.");
    }
    file_stream_ = Make<FileStream>(handle);
    if (file_stream_ == nullptr) {
        CloseHandle(handle);
        std::error_code ignored;
        std::filesystem::remove(path, ignored);
        return Fail(E_OUTOFMEMORY, detail,
                    "Allocating the fragmented MP4 file stream failed.");
    }

    ComPtr<IMFMediaType> resolved_audio_type;
    HRESULT hr = S_OK;
    if (audio_output_type != nullptr) {
        hr = ResolveAacOutputType(audio_output_type, &resolved_audio_type);
        if (FAILED(hr)) {
            Fail(hr, detail,
                 "No installed AAC encoder supports the requested fragmented MP4 profile.");
        }
    }
    if (SUCCEEDED(hr)) {
        hr = MFCreateMFByteStreamOnStream(file_stream_.Get(), &byte_stream_);
    }
    DWORD capabilities = 0;
    if (SUCCEEDED(hr)) {
        hr = byte_stream_->GetCapabilities(&capabilities);
        if (SUCCEEDED(hr) &&
            (capabilities & (MFBYTESTREAM_IS_WRITABLE | MFBYTESTREAM_IS_SEEKABLE)) !=
                (MFBYTESTREAM_IS_WRITABLE | MFBYTESTREAM_IS_SEEKABLE)) {
            hr = E_INVALIDARG;
            Fail(hr, detail,
                 "The fragmented MP4 byte stream is not writable and seekable.");
        }
    }
    if (SUCCEEDED(hr)) {
        hr = MFCreateFMPEG4MediaSink(
            byte_stream_.Get(), video_output_type, resolved_audio_type.Get(), &media_sink_);
    }
    ComPtr<IMFAttributes> sink_attributes;
    if (SUCCEEDED(hr)) {
        hr = media_sink_.As(&sink_attributes);
        if (FAILED(hr)) {
            Fail(hr, detail,
                 "The fragmented MP4 sink does not expose fragment-duration attributes.");
        }
    }
    if (SUCCEEDED(hr)) {
        hr = sink_attributes->SetUINT64(
            MF_MPEG4SINK_MIN_FRAGMENT_DURATION, kMinimumFragmentDuration100ns);
        if (FAILED(hr)) {
            Fail(hr, detail,
                 "Setting the fragmented MP4 minimum fragment duration failed.");
        }
    }
    UINT64 configured_fragment_duration = 0;
    if (SUCCEEDED(hr)) {
        hr = sink_attributes->GetUINT64(
            MF_MPEG4SINK_MIN_FRAGMENT_DURATION, &configured_fragment_duration);
        if (SUCCEEDED(hr) &&
            configured_fragment_duration != kMinimumFragmentDuration100ns) {
            hr = E_UNEXPECTED;
        }
        if (FAILED(hr)) {
            Fail(hr, detail,
                 "The fragmented MP4 sink did not retain its fragment duration.");
        }
    }

    ComPtr<IMFAttributes> attributes;
    if (SUCCEEDED(hr)) {
        hr = MFCreateAttributes(&attributes, 1);
    }
    callback_ = Make<Callback>();
    if (SUCCEEDED(hr) && callback_ == nullptr) {
        hr = E_OUTOFMEMORY;
    }
    if (SUCCEEDED(hr)) {
        hr = attributes->SetUnknown(MF_SINK_WRITER_ASYNC_CALLBACK, callback_.Get());
    }
    if (SUCCEEDED(hr)) {
        hr = MFCreateSinkWriterFromMediaSink(media_sink_.Get(), attributes.Get(), &sink_writer_);
    }
    if (FAILED(hr)) {
        Close();
        std::error_code ignored;
        std::filesystem::remove(path, ignored);
        if (detail == nullptr || detail->empty()) {
            Fail(hr, detail, "Creating the fragmented MP4 media sink failed.");
        }
        return hr;
    }
    return S_OK;
}

HRESULT FragmentedMp4Sink::SetInputMediaType(
    DWORD stream_index, IMFMediaType* input_type) {
    return sink_writer_ == nullptr || input_type == nullptr
        ? E_INVALIDARG
        : sink_writer_->SetInputMediaType(stream_index, input_type, nullptr);
}

HRESULT FragmentedMp4Sink::BeginWriting() {
    if (sink_writer_ == nullptr || begun_writing_) {
        return MF_E_INVALIDREQUEST;
    }
    const HRESULT hr = sink_writer_->BeginWriting();
    if (SUCCEEDED(hr)) {
        begun_writing_ = true;
    }
    return hr;
}

HRESULT FragmentedMp4Sink::WriteSample(DWORD stream_index, IMFSample* sample) {
    if (sink_writer_ == nullptr || !begun_writing_ || finalized_ || sample == nullptr) {
        return MF_E_INVALIDREQUEST;
    }
    return sink_writer_->WriteSample(stream_index, sample);
}

HRESULT FragmentedMp4Sink::CreateDurableCheckpoint(
    const std::vector<DWORD>& stream_indices,
    DurableCheckpoint* checkpoint,
    std::string* detail) {
    if (sink_writer_ == nullptr || !begun_writing_ || finalized_ ||
        stream_indices.empty() || checkpoint == nullptr) {
        return Fail(E_INVALIDARG, detail, "The fragmented MP4 checkpoint request is invalid.");
    }

    // NotifyEndOfSegment only queues an end-of-segment marker.  It is not a
    // durability acknowledgement.  Per-stream markers below establish that
    // all earlier writes traversed the sink before the byte/file flushes.
    HRESULT hr = sink_writer_->NotifyEndOfSegment(
        static_cast<DWORD>(MF_SINK_WRITER_ALL_STREAMS));
    if (SUCCEEDED(hr)) {
        hr = InjectCheckpointFault(CheckpointStage::AfterEndOfSegment);
    }
    std::vector<std::uint64_t> markers;
    markers.reserve(stream_indices.size());
    for (const DWORD stream : stream_indices) {
        if (FAILED(hr)) {
            break;
        }
        const std::uint64_t marker = next_marker_id_++;
        if (marker == 0 || marker > static_cast<std::uint64_t>(UINTPTR_MAX)) {
            hr = E_UNEXPECTED;
            break;
        }
        hr = sink_writer_->PlaceMarker(
            stream, reinterpret_cast<void*>(static_cast<std::uintptr_t>(marker)));
        if (SUCCEEDED(hr)) {
            markers.push_back(marker);
        }
    }
    if (FAILED(hr)) {
        return Fail(hr, detail, "Queueing a fragmented MP4 checkpoint marker failed.");
    }
    if (!callback_->WaitForMarkers(markers)) {
        return Fail(HRESULT_FROM_WIN32(ERROR_TIMEOUT), detail,
                    "Waiting for the fragmented MP4 checkpoint marker timed out.");
    }
    hr = InjectCheckpointFault(CheckpointStage::AfterAllStreamMarkers);
    if (FAILED(hr)) {
        return Fail(hr, detail,
                    "A checkpoint fault was injected after stream markers.");
    }

    std::uint64_t file_size = 0;
    hr = FlushDurably(&file_size, true, detail);
    if (FAILED(hr)) {
        return hr;
    }
    checkpoint->sequence = ++checkpoint_sequence_;
    checkpoint->file_size_bytes = file_size;
    return S_OK;
}

HRESULT FragmentedMp4Sink::FlushDurably(
    std::uint64_t* file_size_bytes, bool allow_fault_hook,
    std::string* detail) {
    if (byte_stream_ == nullptr || file_stream_ == nullptr ||
        file_size_bytes == nullptr) {
        return Fail(E_UNEXPECTED, detail, "The fragmented MP4 flush state is invalid.");
    }
    HRESULT hr = allow_fault_hook
        ? InjectCheckpointFault(CheckpointStage::BeforeByteStreamFlush) : S_OK;
    if (SUCCEEDED(hr)) hr = byte_stream_->Flush();
    if (FAILED(hr)) {
        return Fail(hr, detail, "Flushing the fragmented MP4 byte stream failed.");
    }
    if (allow_fault_hook) {
        hr = InjectCheckpointFault(CheckpointStage::BeforeFileFlush);
    }
    if (SUCCEEDED(hr)) hr = file_stream_->FlushHandle();
    if (FAILED(hr)) {
        return Fail(hr, detail,
                    "Flushing the fragmented MP4 file to storage failed.");
    }
    std::uint64_t size = 0;
    hr = file_stream_->Size(&size);
    if (FAILED(hr)) {
        return Fail(hr, detail,
                    "Reading the fragmented MP4 durable size failed.");
    }
    *file_size_bytes = size;
    return S_OK;
}

HRESULT FragmentedMp4Sink::Finalize(std::string* detail) {
    if (sink_writer_ == nullptr || !begun_writing_ || finalized_) {
        return Fail(MF_E_INVALIDREQUEST, detail,
                    "The fragmented MP4 sink cannot be finalized.");
    }
    callback_->PrepareForFinalize();
    HRESULT hr = sink_writer_->Finalize();
    if (SUCCEEDED(hr)) {
        hr = callback_->WaitForFinalize();
    }
    if (FAILED(hr)) {
        return Fail(hr, detail, "Finalizing the fragmented MP4 sink failed.");
    }
    std::uint64_t ignored_size = 0;
    hr = FlushDurably(&ignored_size, false, detail);
    if (FAILED(hr)) {
        return hr;
    }
    finalized_ = true;
    return S_OK;
}

void FragmentedMp4Sink::Close() noexcept {
    sink_writer_.Reset();
    if (media_sink_ != nullptr) {
        (void)media_sink_->Shutdown();
    }
    media_sink_.Reset();
    byte_stream_.Reset();
    file_stream_.Reset();
    callback_.Reset();
}

}  // namespace recorder::media
