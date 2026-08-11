using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using Recorder.Core;
using TeamsRecorder.Windows.Application.AI;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application.Transcription;

/// <summary>
/// Exports the AAC audio track of a completed managed MP4 (or a legacy M4A) as
/// independently decodable PCM/WAV provider uploads.  The input container is
/// decoded on one dedicated MTA thread; only one bounded staging WAV exists at
/// a time and no whole recording is read into managed memory.
/// </summary>
/// <remarks>
/// This implementation deliberately stays internal. Media Foundation exposes
/// synchronous open/read calls which cannot be safely aborted in-process. The
/// public production path is <see cref="IsolatedMediaFoundationAsrChunkSource"/>,
/// which hosts this decoder in a killable child process.
/// </remarks>
internal sealed class MediaFoundationRecordingSessionAsrChunkSource : IRecordingSessionAsrChunkSource
{
    internal const int WavHeaderBytes = 44;
    internal const string StagingDirectoryPrefix = ".asr-pcm-";
    private readonly IRecordingSessionPcmReaderFactory readerFactory;
    private readonly string? stagingParentFolder;

    internal MediaFoundationRecordingSessionAsrChunkSource()
        : this(new MediaFoundationPcmReaderFactory()) { }

    internal MediaFoundationRecordingSessionAsrChunkSource(IRecordingSessionPcmReaderFactory readerFactory, string? stagingParentFolder = null)
    {
        this.readerFactory = readerFactory ?? throw new ArgumentNullException(nameof(readerFactory));
        this.stagingParentFolder = stagingParentFolder;
    }

    public async IAsyncEnumerable<RecordingSessionAsrChunk> ReadChunksAsync(
        RecordingSessionPlan plan,
        RecordingSessionAsrChunkConstraints constraints,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var media = RecordingSessionAsrMediaResolver.Resolve(plan);
        ValidateConstraints(constraints);
        cancellationToken.ThrowIfCancellationRequested();

        var staging = CreateStagingDirectory(stagingParentFolder ?? media.FolderPath);
        using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        using var slots = new SemaphoreSlim(1, 1);
        Task producer = Task.CompletedTask;
        try
        {
            var channel = Channel.CreateBounded<PreparedChunk>(new BoundedChannelOptions(1)
            {
                SingleReader = true,
                SingleWriter = true,
                FullMode = BoundedChannelFullMode.Wait,
            });
            producer = StartProducer(media, constraints, staging, slots, channel.Writer, linkedCancellation.Token);
            await foreach (var prepared in channel.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
            {
                byte[] audio;
                try
                {
                    audio = await ReadBoundedChunkAsync(prepared, constraints, cancellationToken).ConfigureAwait(false);
                }
                catch
                {
                    DeletePreparedChunk(prepared.Path);
                    slots.Release();
                    throw;
                }

                try
                {
                    yield return new RecordingSessionAsrChunk(prepared.Sequence, prepared.Duration, audio, prepared.FileName);
                }
                finally
                {
                    // The caller owns the byte[] until it asks for the next chunk.  Do
                    // not permit the decoder to stage another file before that caller
                    // has completed (or abandoned) the current provider upload.
                    DeletePreparedChunk(prepared.Path);
                    slots.Release();
                }
            }

            await producer.ConfigureAwait(false);
        }
        finally
        {
            linkedCancellation.Cancel();
            try
            {
                await producer.ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (linkedCancellation.IsCancellationRequested) { }
            catch when (cancellationToken.IsCancellationRequested) { }
            // A producer failure has already been projected through the channel
            // (or the explicit await in the body). Do not let observing the same
            // task again skip bounded staging cleanup from this finally block.
            catch (Exception) { }
            DeleteStagingDirectory(staging);
        }
    }

    private Task StartProducer(
        ResolvedRecordingSessionMedia media,
        RecordingSessionAsrChunkConstraints constraints,
        string staging,
        SemaphoreSlim slots,
        ChannelWriter<PreparedChunk> writer,
        CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                Produce(media, constraints, staging, slots, writer, cancellationToken);
                writer.TryComplete();
                completion.TrySetResult();
            }
            catch (OperationCanceledException error) when (cancellationToken.IsCancellationRequested)
            {
                writer.TryComplete(error);
                completion.TrySetCanceled(cancellationToken);
            }
            catch (Exception error)
            {
                writer.TryComplete(error);
                completion.TrySetException(error);
            }
        })
        {
            IsBackground = true,
            Name = "TeamsRecorder ASR media decoder",
        };
        thread.Start();
        return completion.Task;
    }

    private void Produce(
        ResolvedRecordingSessionMedia media,
        RecordingSessionAsrChunkConstraints constraints,
        string staging,
        SemaphoreSlim slots,
        ChannelWriter<PreparedChunk> writer,
        CancellationToken cancellationToken)
    {
        using var reader = readerFactory.Open(media.Path);
        var format = reader.Format;
        format.Validate();
        var maximumDataBytes = MaximumDataBytes(format, constraints);
        var sequence = 0;
        WavChunkWriter? chunk = null;
        var sawAudio = false;
        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var sample = reader.Read(cancellationToken);
                if (sample is null) break;
                if (sample.Value.Length == 0 || sample.Value.Length % format.BlockAlignment != 0)
                    throw new IOException($"Media Foundation produced an invalid PCM audio sample length {sample.Value.Length} for block alignment {format.BlockAlignment}.");
                sawAudio = true;
                var offset = 0;
                while (offset < sample.Value.Length)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (chunk is null)
                    {
                        slots.Wait(cancellationToken);
                        try
                        {
                            chunk = WavChunkWriter.Create(staging, sequence, format, maximumDataBytes);
                        }
                        catch
                        {
                            slots.Release();
                            throw;
                        }
                    }

                    offset += chunk.Write(sample.Value.Span[offset..]);
                    if (chunk.IsFull)
                    {
                        var prepared = chunk.Complete();
                        chunk = null;
                        WritePreparedChunk(writer, prepared, cancellationToken);
                        sequence++;
                    }
                }
            }

            if (chunk is not null)
            {
                if (!chunk.HasAudio) throw new IOException("The completed recording has no decodable audio samples.");
                var prepared = chunk.Complete();
                chunk = null;
                WritePreparedChunk(writer, prepared, cancellationToken);
                sequence++;
            }

            if (!sawAudio || sequence == 0)
                throw new IOException("The completed recording has no decodable audio samples.");
        }
        finally
        {
            if (chunk is not null)
            {
                chunk.Dispose();
                slots.Release();
            }
        }
    }

    private static void WritePreparedChunk(ChannelWriter<PreparedChunk> writer, PreparedChunk prepared, CancellationToken cancellationToken)
    {
        // Keep the Media Foundation reader on this dedicated MTA thread.  The
        // bounded channel provides the back-pressure, so blocking here cannot
        // block the UI or the provider request that consumes the prior chunk.
        writer.WriteAsync(prepared, cancellationToken).AsTask().GetAwaiter().GetResult();
    }

    private static async Task<byte[]> ReadBoundedChunkAsync(
        PreparedChunk prepared,
        RecordingSessionAsrChunkConstraints constraints,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        EnsureSafeRegularFile(prepared.Path);
        var length = new FileInfo(prepared.Path).Length;
        if (length <= WavHeaderBytes || length > constraints.MaximumBytes)
            throw new IOException("The staged transcription chunk exceeds its provider upload limit.");
        var audio = await File.ReadAllBytesAsync(prepared.Path, cancellationToken).ConfigureAwait(false);
        if (audio.Length != length || audio.Length > constraints.MaximumBytes || !IsCompletePcmWav(audio))
            throw new IOException("The staged transcription chunk is not a complete bounded WAV file.");
        return audio;
    }

    private static long MaximumDataBytes(PcmAudioFormat format, RecordingSessionAsrChunkConstraints constraints)
    {
        var bytesByDuration = checked((long)((decimal)constraints.MaximumDuration.Ticks * format.SampleRate / TimeSpan.TicksPerSecond)) * format.BlockAlignment;
        var bytesBySize = ((long)constraints.MaximumBytes - WavHeaderBytes) / format.BlockAlignment * format.BlockAlignment;
        var result = Math.Min(bytesByDuration, bytesBySize);
        if (result < format.BlockAlignment)
            throw new ArgumentOutOfRangeException(nameof(constraints), "The configured upload cap cannot contain one PCM frame.");
        return result;
    }

    private static void ValidateConstraints(RecordingSessionAsrChunkConstraints constraints)
    {
        ArgumentNullException.ThrowIfNull(constraints);
        if (constraints.MaximumDuration <= TimeSpan.Zero ||
            constraints.MaximumDuration > RecordingSessionAsrChunkConstraints.ProviderDefault.MaximumDuration ||
            constraints.MaximumBytes <= WavHeaderBytes ||
            constraints.MaximumBytes > RecordingSessionAsrChunkConstraints.ProviderDefault.MaximumBytes)
            throw new ArgumentOutOfRangeException(nameof(constraints), "ASR chunk constraints exceed the supported provider limits.");
    }

    private static string CreateStagingDirectory(string folder)
    {
        CleanupStaleStagingDirectories(folder);
        var staging = Path.Combine(folder, StagingDirectoryPrefix + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        if ((File.GetAttributes(staging) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Refusing to stage transcription audio in a reparse-point directory.");
        return staging;
    }

    private static void CleanupStaleStagingDirectories(string folder)
    {
        var earliest = DateTime.UtcNow - TimeSpan.FromHours(24);
        foreach (var candidate in Directory.EnumerateDirectories(folder, StagingDirectoryPrefix + "*", SearchOption.TopDirectoryOnly))
        {
            try
            {
                var info = new DirectoryInfo(candidate);
                if ((info.Attributes & FileAttributes.ReparsePoint) == 0 && info.CreationTimeUtc < earliest)
                    info.Delete(recursive: true);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static void DeleteStagingDirectory(string staging)
    {
        try
        {
            if (Directory.Exists(staging) && (File.GetAttributes(staging) & FileAttributes.ReparsePoint) == 0)
                Directory.Delete(staging, recursive: true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void DeletePreparedChunk(string path)
    {
        try
        {
            if (File.Exists(path) && (File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0)
                File.Delete(path);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void EnsureSafeRegularFile(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException("The staged transcription chunk is not a regular file.");
    }

    internal static bool IsCompletePcmWav(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < WavHeaderBytes ||
            !bytes[..4].SequenceEqual("RIFF"u8) ||
            !bytes.Slice(8, 4).SequenceEqual("WAVE"u8) ||
            !bytes.Slice(12, 4).SequenceEqual("fmt "u8) ||
            !bytes.Slice(36, 4).SequenceEqual("data"u8)) return false;
        var riffLength = BitConverter.ToUInt32(bytes.Slice(4, 4));
        var fmtLength = BitConverter.ToUInt32(bytes.Slice(16, 4));
        var formatTag = BitConverter.ToUInt16(bytes.Slice(20, 2));
        var channels = BitConverter.ToUInt16(bytes.Slice(22, 2));
        var sampleRate = BitConverter.ToUInt32(bytes.Slice(24, 4));
        var averageBytesPerSecond = BitConverter.ToUInt32(bytes.Slice(28, 4));
        var blockAlignment = BitConverter.ToUInt16(bytes.Slice(32, 2));
        var bitsPerSample = BitConverter.ToUInt16(bytes.Slice(34, 2));
        var dataLength = BitConverter.ToUInt32(bytes.Slice(40, 4));
        return fmtLength == 16 && formatTag == 1 && channels > 0 && sampleRate > 0 && bitsPerSample == 16 &&
            blockAlignment == channels * 2 && averageBytesPerSecond == sampleRate * blockAlignment &&
            dataLength == bytes.Length - WavHeaderBytes && riffLength == bytes.Length - 8 && dataLength % blockAlignment == 0;
    }

    private sealed record PreparedChunk(int Sequence, TimeSpan Duration, string Path, string FileName);

    private sealed class WavChunkWriter : IDisposable
    {
        private readonly string partialPath;
        private readonly string finalPath;
        private readonly int sequence;
        private readonly PcmAudioFormat format;
        private readonly long maximumDataBytes;
        private FileStream? stream;
        private long dataBytes;

        private WavChunkWriter(string partialPath, string finalPath, int sequence, PcmAudioFormat format, long maximumDataBytes)
        {
            this.partialPath = partialPath;
            this.finalPath = finalPath;
            this.sequence = sequence;
            this.format = format;
            this.maximumDataBytes = maximumDataBytes;
            stream = new FileStream(partialPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 64 * 1024,
                FileOptions.SequentialScan | FileOptions.WriteThrough);
            stream.Write(new byte[WavHeaderBytes]);
        }

        public bool HasAudio => dataBytes > 0;
        public bool IsFull => dataBytes == maximumDataBytes;

        public static WavChunkWriter Create(string staging, int sequence, PcmAudioFormat format, long maximumDataBytes)
        {
            var fileName = $"transcription-{sequence:D4}.wav";
            return new(Path.Combine(staging, fileName + ".partial"), Path.Combine(staging, fileName), sequence, format, maximumDataBytes);
        }

        public int Write(ReadOnlySpan<byte> source)
        {
            var destination = stream ?? throw new ObjectDisposedException(nameof(WavChunkWriter));
            var writable = checked((int)Math.Min(source.Length, maximumDataBytes - dataBytes));
            writable -= writable % format.BlockAlignment;
            if (writable <= 0) return 0;
            destination.Write(source[..writable]);
            dataBytes += writable;
            return writable;
        }

        public PreparedChunk Complete()
        {
            if (!HasAudio) throw new IOException("Cannot create an empty transcription WAV chunk.");
            var destination = stream ?? throw new ObjectDisposedException(nameof(WavChunkWriter));
            destination.Position = 0;
            WriteHeader(destination, format, checked((uint)dataBytes));
            destination.Flush(flushToDisk: true);
            destination.Dispose();
            stream = null;
            File.Move(partialPath, finalPath, false);
            var frames = dataBytes / format.BlockAlignment;
            var durationTicks = checked((long)((decimal)frames * TimeSpan.TicksPerSecond / format.SampleRate));
            return new PreparedChunk(
                sequence,
                TimeSpan.FromTicks(durationTicks), finalPath, Path.GetFileName(finalPath));
        }

        public void Dispose()
        {
            stream?.Dispose();
            stream = null;
            try { if (File.Exists(partialPath)) File.Delete(partialPath); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }

        private static void WriteHeader(Stream output, PcmAudioFormat format, uint dataBytes)
        {
            Span<byte> header = stackalloc byte[WavHeaderBytes];
            "RIFF"u8.CopyTo(header);
            BitConverter.TryWriteBytes(header.Slice(4, 4), checked(dataBytes + 36));
            "WAVEfmt "u8.CopyTo(header.Slice(8));
            BitConverter.TryWriteBytes(header.Slice(16, 4), 16u);
            BitConverter.TryWriteBytes(header.Slice(20, 2), (ushort)1);
            BitConverter.TryWriteBytes(header.Slice(22, 2), checked((ushort)format.Channels));
            BitConverter.TryWriteBytes(header.Slice(24, 4), checked((uint)format.SampleRate));
            BitConverter.TryWriteBytes(header.Slice(28, 4), checked((uint)format.AverageBytesPerSecond));
            BitConverter.TryWriteBytes(header.Slice(32, 2), checked((ushort)format.BlockAlignment));
            BitConverter.TryWriteBytes(header.Slice(34, 2), checked((ushort)format.BitsPerSample));
            "data"u8.CopyTo(header.Slice(36));
            BitConverter.TryWriteBytes(header.Slice(40, 4), dataBytes);
            output.Write(header);
        }
    }
}

/// <summary>Resolved from a managed session's two accepted final media names only.</summary>
public sealed record ResolvedRecordingSessionMedia(string FolderPath, string Path, string FileName);

public static class RecordingSessionAsrMediaResolver
{
    private const string LegacyM4aFileName = "recording.m4a";

    public static ResolvedRecordingSessionMedia Resolve(RecordingSessionPlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var folder = Path.GetFullPath(plan.FolderPath);
        if (!Directory.Exists(folder) || IsReparsePoint(folder) ||
            !RecordingSessionLayout.TryGetKind(Path.GetFileName(folder), out var kind) || kind != plan.Kind)
            throw new IOException("Transcription requires an owned recording session folder.");

        // The new Windows publication name is recording.mp4.  Keep m4a only as
        // a legacy input so an older session never causes a whole-file upload.
        var candidates = new List<string>
        {
            Path.Combine(folder, RecordingSessionLayout.FinalVideoFileName),
            Path.Combine(folder, LegacyM4aFileName),
        };
        var metadataPath = Path.Combine(folder, RecordingSessionLayout.MetadataFileName);
        var metadata = ReadSafeMetadata(metadataPath);
        if (string.Equals(metadata.Source, "imported", StringComparison.Ordinal))
        {
            candidates.AddRange(RecordingSessionLayout.ImportedAudioExtensions
                .Where(extension => !string.Equals(extension, "m4a", StringComparison.OrdinalIgnoreCase))
                .Select(extension => Path.Combine(folder, $"recording.{extension}")));
        }
        foreach (var candidate in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!File.Exists(candidate)) continue;
            var attributes = File.GetAttributes(candidate);
            if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || new FileInfo(candidate).Length <= 0)
                throw new IOException("The completed recording media is not a safe regular file.");
            return new ResolvedRecordingSessionMedia(folder, candidate, Path.GetFileName(candidate));
        }

        throw new IOException("Transcription requires completed managed media or an explicitly imported supported audio file.");
    }

    private static bool IsReparsePoint(string path) => (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;

    private static RecordingInfo ReadSafeMetadata(string path)
    {
        try
        {
            if (!File.Exists(path)) return RecordingInfoJson.Parse(null);
            var attributes = File.GetAttributes(path);
            if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                return RecordingInfoJson.Parse(null);
            return RecordingInfoJson.Parse(File.ReadAllText(path));
        }
        catch (IOException) { return RecordingInfoJson.Parse(null); }
        catch (UnauthorizedAccessException) { return RecordingInfoJson.Parse(null); }
    }
}

internal readonly record struct PcmAudioFormat(int SampleRate, int Channels, int BitsPerSample)
{
    public int BlockAlignment => checked(Channels * (BitsPerSample / 8));
    public int AverageBytesPerSecond => checked(SampleRate * BlockAlignment);

    public void Validate()
    {
        if (SampleRate is < 8_000 or > 192_000 || Channels is < 1 or > 2 || BitsPerSample != 16 || BlockAlignment <= 0)
            throw new IOException("Media Foundation did not provide supported 16-bit PCM audio.");
    }
}

internal interface IRecordingSessionPcmReaderFactory
{
    IRecordingSessionPcmReader Open(string mediaPath);
}

internal interface IRecordingSessionPcmReader : IDisposable
{
    PcmAudioFormat Format { get; }
    ReadOnlyMemory<byte>? Read(CancellationToken cancellationToken);
}

internal sealed class MediaFoundationPcmReaderFactory : IRecordingSessionPcmReaderFactory
{
    public IRecordingSessionPcmReader Open(string mediaPath) => new MediaFoundationPcmReader(mediaPath);
}

internal sealed class MediaFoundationPcmReader : IRecordingSessionPcmReader
{
    private const uint FirstAudioStream = 0xfffffffdu;
    private const uint AllStreams = 0xfffffffeu;
    private const uint EndOfStream = 0x00000002u;
    private const uint Error = 0x00000001u;
    private const uint NativeMediaTypeChanged = 0x00000010u;
    private const uint CurrentMediaTypeChanged = 0x00000020u;
    private const int MaximumEmptyReads = 256;
    private const int MaximumDecodedSampleBytes = 4 * 1024 * 1024;
    private readonly MediaFoundationRuntime runtime;
    private IMFSourceReader? reader;
    private bool eosAfterSample;

    public MediaFoundationPcmReader(string mediaPath)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Media Foundation ASR chunk export requires Windows.");
        if (string.IsNullOrWhiteSpace(mediaPath) || !Path.IsPathFullyQualified(mediaPath))
            throw new IOException("Media Foundation requires an absolute completed media path.");
        runtime = new MediaFoundationRuntime();
        try
        {
            HResult.ThrowIfFailed(MFNative.MFCreateSourceReaderFromURL(mediaPath, null, out var created), "Media Foundation could not open the completed recording.");
            reader = created;
            HResult.ThrowIfFailed(reader.SetStreamSelection(AllStreams, false), "Media Foundation could not deselect non-audio streams.");
            HResult.ThrowIfFailed(reader.SetStreamSelection(FirstAudioStream, true), "The completed recording has no readable audio stream.");
            HResult.ThrowIfFailed(MFNative.MFCreateMediaType(out var requested), "Media Foundation could not allocate a PCM media type.");
            try
            {
                ConfigurePcm(requested);
                HResult.ThrowIfFailed(reader.SetCurrentMediaType(FirstAudioStream, IntPtr.Zero, requested), "The completed recording cannot decode to the required PCM format.");
            }
            finally { ReleaseComObject(requested); }
            HResult.ThrowIfFailed(reader.GetCurrentMediaType(FirstAudioStream, out var current), "Media Foundation did not report a decoded PCM format.");
            try { Format = ReadAndValidatePcmFormat(current); }
            finally { ReleaseComObject(current); }
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    public PcmAudioFormat Format { get; }

    public ReadOnlyMemory<byte>? Read(CancellationToken cancellationToken)
    {
        var active = reader ?? throw new ObjectDisposedException(nameof(MediaFoundationPcmReader));
        if (eosAfterSample) return null;
        for (var attempt = 0; attempt < MaximumEmptyReads; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            HResult.ThrowIfFailed(active.ReadSample(FirstAudioStream, 0, out _, out var flags, out _, out var sample),
                "Media Foundation failed while decoding the completed recording.");
            try
            {
                if ((flags & (Error | NativeMediaTypeChanged | CurrentMediaTypeChanged)) != 0)
                    throw new IOException("Media Foundation reported a decode error or an unsupported format change.");
                if (sample is not null)
                {
                    var bytes = CopyPcm(sample, Format.BlockAlignment);
                    eosAfterSample = (flags & EndOfStream) != 0;
                    return bytes;
                }
                if ((flags & EndOfStream) != 0) return null;
            }
            finally { ReleaseComObject(sample); }
        }
        throw new IOException("Media Foundation did not produce audio within the bounded read limit.");
    }

    public void Dispose()
    {
        var active = Interlocked.Exchange(ref reader, null);
        ReleaseComObject(active);
        runtime.Dispose();
    }

    private static void ConfigurePcm(IMFMediaType mediaType)
    {
        HResult.ThrowIfFailed(mediaType.SetGUID(MFGuids.MediaTypeMajor, MFGuids.MediaTypeAudio), "Could not configure decoded audio type.");
        HResult.ThrowIfFailed(mediaType.SetGUID(MFGuids.MediaTypeSubtype, MFGuids.AudioFormatPcm), "Could not configure PCM decoding.");
        HResult.ThrowIfFailed(mediaType.SetUINT32(MFGuids.AudioChannels, 2), "Could not configure decoded audio channels.");
        HResult.ThrowIfFailed(mediaType.SetUINT32(MFGuids.AudioSamplesPerSecond, 48_000), "Could not configure decoded audio rate.");
        HResult.ThrowIfFailed(mediaType.SetUINT32(MFGuids.AudioBitsPerSample, 16), "Could not configure decoded audio bit depth.");
        HResult.ThrowIfFailed(mediaType.SetUINT32(MFGuids.AudioBlockAlignment, 4), "Could not configure decoded audio block alignment.");
        HResult.ThrowIfFailed(mediaType.SetUINT32(MFGuids.AudioAverageBytesPerSecond, 192_000), "Could not configure decoded audio byte rate.");
    }

    private static PcmAudioFormat ReadAndValidatePcmFormat(IMFMediaType mediaType)
    {
        HResult.ThrowIfFailed(mediaType.GetGUID(MFGuids.MediaTypeMajor, out var major), "Media Foundation did not report an audio major type.");
        HResult.ThrowIfFailed(mediaType.GetGUID(MFGuids.MediaTypeSubtype, out var subtype), "Media Foundation did not report a PCM subtype.");
        if (major != MFGuids.MediaTypeAudio || subtype != MFGuids.AudioFormatPcm)
            throw new IOException("Media Foundation did not decode the recording to PCM audio.");
        HResult.ThrowIfFailed(mediaType.GetUINT32(MFGuids.AudioSamplesPerSecond, out var sampleRate), "Media Foundation did not report an audio rate.");
        HResult.ThrowIfFailed(mediaType.GetUINT32(MFGuids.AudioChannels, out var channels), "Media Foundation did not report audio channels.");
        HResult.ThrowIfFailed(mediaType.GetUINT32(MFGuids.AudioBitsPerSample, out var bits), "Media Foundation did not report audio bit depth.");
        var format = new PcmAudioFormat(checked((int)sampleRate), checked((int)channels), checked((int)bits));
        format.Validate();
        HResult.ThrowIfFailed(mediaType.GetUINT32(MFGuids.AudioBlockAlignment, out var blockAlignment), "Media Foundation did not report audio block alignment.");
        if (blockAlignment != format.BlockAlignment)
            throw new IOException("Media Foundation reported an inconsistent PCM block alignment.");
        return format;
    }

    private static byte[] CopyPcm(IMFSample sample, int blockAlignment)
    {
        HResult.ThrowIfFailed(sample.ConvertToContiguousBuffer(out var buffer), "Media Foundation could not flatten decoded PCM audio.");
        try
        {
            HResult.ThrowIfFailed(buffer.Lock(out var pointer, out _, out var length), "Media Foundation could not lock decoded PCM audio.");
            try
            {
                if (pointer == IntPtr.Zero || length == 0 || length > MaximumDecodedSampleBytes || length % blockAlignment != 0)
                    throw new IOException("Media Foundation returned an invalid decoded PCM buffer.");
                var bytes = new byte[length];
                Marshal.Copy(pointer, bytes, 0, checked((int)length));
                return bytes;
            }
            finally { HResult.ThrowIfFailed(buffer.Unlock(), "Media Foundation could not unlock decoded PCM audio."); }
        }
        finally { ReleaseComObject(buffer); }
    }

    private static void ReleaseComObject(object? value)
    {
        if (OperatingSystem.IsWindows() && value is not null && Marshal.IsComObject(value)) Marshal.FinalReleaseComObject(value);
    }
}

internal sealed class MediaFoundationRuntime : IDisposable
{
    private const int RpcEChangedMode = unchecked((int)0x80010106);
    private bool initializedCom;
    private bool started;

    public MediaFoundationRuntime()
    {
        var coInitialize = MFNative.CoInitializeEx(IntPtr.Zero, 0);
        if (coInitialize >= 0) initializedCom = true;
        else if (coInitialize != RpcEChangedMode) HResult.ThrowIfFailed(coInitialize, "Could not initialize the Media Foundation decoder thread.");
        HResult.ThrowIfFailed(MFNative.MFStartup(0x0002_0070, 0), "Could not start Media Foundation for transcription.");
        started = true;
    }

    public void Dispose()
    {
        if (started) { MFNative.MFShutdown(); started = false; }
        if (initializedCom) { MFNative.CoUninitialize(); initializedCom = false; }
    }
}

internal static class HResult
{
    public static void ThrowIfFailed(int value, string message)
    {
        if (value < 0) throw new IOException(message + " (0x" + value.ToString("X8", System.Globalization.CultureInfo.InvariantCulture) + ").", Marshal.GetExceptionForHR(value));
    }
}

internal static class MFNative
{
    [DllImport("mfplat.dll", ExactSpelling = true)] public static extern int MFStartup(uint version, uint flags);
    [DllImport("mfplat.dll", ExactSpelling = true)] public static extern int MFShutdown();
    [DllImport("mfplat.dll", ExactSpelling = true)] public static extern int MFCreateMediaType([MarshalAs(UnmanagedType.Interface)] out IMFMediaType mediaType);
    [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int MFCreateSourceReaderFromURL(string url, [MarshalAs(UnmanagedType.Interface)] IMFAttributes? attributes, [MarshalAs(UnmanagedType.Interface)] out IMFSourceReader reader);
    [DllImport("ole32.dll", ExactSpelling = true)] public static extern int CoInitializeEx(IntPtr reserved, uint coInit);
    [DllImport("ole32.dll", ExactSpelling = true)] public static extern void CoUninitialize();
}

internal static class MFGuids
{
    public static readonly Guid MediaTypeMajor = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static readonly Guid MediaTypeSubtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static readonly Guid AudioChannels = new("37e48bf5-645e-4c5b-89de-ada9e29b696a");
    public static readonly Guid AudioSamplesPerSecond = new("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    public static readonly Guid AudioBlockAlignment = new("322de230-9eeb-43bd-ab7a-ff412251541d");
    public static readonly Guid AudioBitsPerSample = new("f2deb57f-40fa-4764-aa33-ed4f2d1ff669");
    public static readonly Guid AudioAverageBytesPerSecond = new("1aab75c8-cfef-451c-ab95-ac034b8e1731");
    public static readonly Guid MediaTypeAudio = new("73647561-0000-0010-8000-00aa00389b71");
    public static readonly Guid AudioFormatPcm = new("00000001-0000-0010-8000-00aa00389b71");
}

[ComImport, Guid("2cd2d921-c447-44a7-a13c-4adabfc247e3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFAttributes
{
    [PreserveSig] int GetItem(in Guid key, IntPtr value);
    [PreserveSig] int GetItemType(in Guid key, out int type);
    [PreserveSig] int CompareItem(in Guid key, IntPtr value, out bool result);
    [PreserveSig] int Compare([MarshalAs(UnmanagedType.Interface)] IMFAttributes theirs, int matchType, out bool result);
    [PreserveSig] int GetUINT32(in Guid key, out uint value);
    [PreserveSig] int GetUINT64(in Guid key, out ulong value);
    [PreserveSig] int GetDouble(in Guid key, out double value);
    [PreserveSig] int GetGUID(in Guid key, out Guid value);
    [PreserveSig] int GetStringLength(in Guid key, out uint length);
    [PreserveSig] int GetString(in Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value, uint length, IntPtr actualLength);
    [PreserveSig] int GetAllocatedString(in Guid key, out IntPtr value, out uint length);
    [PreserveSig] int GetBlobSize(in Guid key, out uint size);
    [PreserveSig] int GetBlob(in Guid key, IntPtr buffer, uint size, IntPtr actualSize);
    [PreserveSig] int GetAllocatedBlob(in Guid key, out IntPtr buffer, out uint size);
    [PreserveSig] int GetUnknown(in Guid key, in Guid riid, out IntPtr value);
    [PreserveSig] int SetItem(in Guid key, IntPtr value);
    [PreserveSig] int DeleteItem(in Guid key);
    [PreserveSig] int DeleteAllItems();
    [PreserveSig] int SetUINT32(in Guid key, uint value);
    [PreserveSig] int SetUINT64(in Guid key, ulong value);
    [PreserveSig] int SetDouble(in Guid key, double value);
    [PreserveSig] int SetGUID(in Guid key, in Guid value);
    [PreserveSig] int SetString(in Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
    [PreserveSig] int SetBlob(in Guid key, IntPtr buffer, uint size);
    [PreserveSig] int SetUnknown(in Guid key, [MarshalAs(UnmanagedType.IUnknown)] object value);
    [PreserveSig] int LockStore();
    [PreserveSig] int UnlockStore();
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetItemByIndex(uint index, out Guid key, IntPtr value);
    [PreserveSig] int CopyAllItems([MarshalAs(UnmanagedType.Interface)] IMFAttributes destination);
}

[ComImport, Guid("44ae0fa8-ea31-4109-8d2e-4cae4997c555"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFMediaType : IMFAttributes
{
    [PreserveSig] new int GetItem(in Guid key, IntPtr value);
    [PreserveSig] new int GetItemType(in Guid key, out int type);
    [PreserveSig] new int CompareItem(in Guid key, IntPtr value, out bool result);
    [PreserveSig] new int Compare([MarshalAs(UnmanagedType.Interface)] IMFAttributes theirs, int matchType, out bool result);
    [PreserveSig] new int GetUINT32(in Guid key, out uint value);
    [PreserveSig] new int GetUINT64(in Guid key, out ulong value);
    [PreserveSig] new int GetDouble(in Guid key, out double value);
    [PreserveSig] new int GetGUID(in Guid key, out Guid value);
    [PreserveSig] new int GetStringLength(in Guid key, out uint length);
    [PreserveSig] new int GetString(in Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value, uint length, IntPtr actualLength);
    [PreserveSig] new int GetAllocatedString(in Guid key, out IntPtr value, out uint length);
    [PreserveSig] new int GetBlobSize(in Guid key, out uint size);
    [PreserveSig] new int GetBlob(in Guid key, IntPtr buffer, uint size, IntPtr actualSize);
    [PreserveSig] new int GetAllocatedBlob(in Guid key, out IntPtr buffer, out uint size);
    [PreserveSig] new int GetUnknown(in Guid key, in Guid riid, out IntPtr value);
    [PreserveSig] new int SetItem(in Guid key, IntPtr value);
    [PreserveSig] new int DeleteItem(in Guid key);
    [PreserveSig] new int DeleteAllItems();
    [PreserveSig] new int SetUINT32(in Guid key, uint value);
    [PreserveSig] new int SetUINT64(in Guid key, ulong value);
    [PreserveSig] new int SetDouble(in Guid key, double value);
    [PreserveSig] new int SetGUID(in Guid key, in Guid value);
    [PreserveSig] new int SetString(in Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
    [PreserveSig] new int SetBlob(in Guid key, IntPtr buffer, uint size);
    [PreserveSig] new int SetUnknown(in Guid key, [MarshalAs(UnmanagedType.IUnknown)] object value);
    [PreserveSig] new int LockStore();
    [PreserveSig] new int UnlockStore();
    [PreserveSig] new int GetCount(out uint count);
    [PreserveSig] new int GetItemByIndex(uint index, out Guid key, IntPtr value);
    [PreserveSig] new int CopyAllItems([MarshalAs(UnmanagedType.Interface)] IMFAttributes destination);
    [PreserveSig] int GetMajorType(out Guid majorType);
    [PreserveSig] int IsCompressedFormat([MarshalAs(UnmanagedType.Bool)] out bool compressed);
    [PreserveSig] int IsEqual([MarshalAs(UnmanagedType.Interface)] IMFMediaType type, out uint flags);
    [PreserveSig] int GetRepresentation(in Guid representation, out IntPtr value);
    [PreserveSig] int FreeRepresentation(in Guid representation, IntPtr value);
}

[ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFSample : IMFAttributes
{
    [PreserveSig] new int GetItem(in Guid key, IntPtr value);
    [PreserveSig] new int GetItemType(in Guid key, out int type);
    [PreserveSig] new int CompareItem(in Guid key, IntPtr value, out bool result);
    [PreserveSig] new int Compare([MarshalAs(UnmanagedType.Interface)] IMFAttributes theirs, int matchType, out bool result);
    [PreserveSig] new int GetUINT32(in Guid key, out uint value);
    [PreserveSig] new int GetUINT64(in Guid key, out ulong value);
    [PreserveSig] new int GetDouble(in Guid key, out double value);
    [PreserveSig] new int GetGUID(in Guid key, out Guid value);
    [PreserveSig] new int GetStringLength(in Guid key, out uint length);
    [PreserveSig] new int GetString(in Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value, uint length, IntPtr actualLength);
    [PreserveSig] new int GetAllocatedString(in Guid key, out IntPtr value, out uint length);
    [PreserveSig] new int GetBlobSize(in Guid key, out uint size);
    [PreserveSig] new int GetBlob(in Guid key, IntPtr buffer, uint size, IntPtr actualSize);
    [PreserveSig] new int GetAllocatedBlob(in Guid key, out IntPtr buffer, out uint size);
    [PreserveSig] new int GetUnknown(in Guid key, in Guid riid, out IntPtr value);
    [PreserveSig] new int SetItem(in Guid key, IntPtr value);
    [PreserveSig] new int DeleteItem(in Guid key);
    [PreserveSig] new int DeleteAllItems();
    [PreserveSig] new int SetUINT32(in Guid key, uint value);
    [PreserveSig] new int SetUINT64(in Guid key, ulong value);
    [PreserveSig] new int SetDouble(in Guid key, double value);
    [PreserveSig] new int SetGUID(in Guid key, in Guid value);
    [PreserveSig] new int SetString(in Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
    [PreserveSig] new int SetBlob(in Guid key, IntPtr buffer, uint size);
    [PreserveSig] new int SetUnknown(in Guid key, [MarshalAs(UnmanagedType.IUnknown)] object value);
    [PreserveSig] new int LockStore();
    [PreserveSig] new int UnlockStore();
    [PreserveSig] new int GetCount(out uint count);
    [PreserveSig] new int GetItemByIndex(uint index, out Guid key, IntPtr value);
    [PreserveSig] new int CopyAllItems([MarshalAs(UnmanagedType.Interface)] IMFAttributes destination);
    [PreserveSig] int GetSampleFlags(out uint flags);
    [PreserveSig] int SetSampleFlags(uint flags);
    [PreserveSig] int GetSampleTime(out long time);
    [PreserveSig] int SetSampleTime(long time);
    [PreserveSig] int GetSampleDuration(out long duration);
    [PreserveSig] int SetSampleDuration(long duration);
    [PreserveSig] int GetBufferCount(out uint count);
    [PreserveSig] int GetBufferByIndex(uint index, [MarshalAs(UnmanagedType.Interface)] out IMFMediaBuffer buffer);
    [PreserveSig] int ConvertToContiguousBuffer([MarshalAs(UnmanagedType.Interface)] out IMFMediaBuffer buffer);
    [PreserveSig] int AddBuffer([MarshalAs(UnmanagedType.Interface)] IMFMediaBuffer buffer);
    [PreserveSig] int RemoveBufferByIndex(uint index);
    [PreserveSig] int RemoveAllBuffers();
    [PreserveSig] int GetTotalLength(out uint length);
    [PreserveSig] int CopyToBuffer([MarshalAs(UnmanagedType.Interface)] IMFMediaBuffer buffer);
}

[ComImport, Guid("045FA593-8799-42b8-BC8D-8968C6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFMediaBuffer
{
    [PreserveSig] int Lock(out IntPtr buffer, out uint maximumLength, out uint currentLength);
    [PreserveSig] int Unlock();
    [PreserveSig] int GetCurrentLength(out uint currentLength);
    [PreserveSig] int SetCurrentLength(uint currentLength);
    [PreserveSig] int GetMaxLength(out uint maximumLength);
}

[ComImport, Guid("70ae66f2-c809-4e4f-8915-bdcb406b7993"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFSourceReader
{
    [PreserveSig] int GetStreamSelection(uint streamIndex, [MarshalAs(UnmanagedType.Bool)] out bool selected);
    [PreserveSig] int SetStreamSelection(uint streamIndex, [MarshalAs(UnmanagedType.Bool)] bool selected);
    [PreserveSig] int GetNativeMediaType(uint streamIndex, uint mediaTypeIndex, [MarshalAs(UnmanagedType.Interface)] out IMFMediaType mediaType);
    [PreserveSig] int GetCurrentMediaType(uint streamIndex, [MarshalAs(UnmanagedType.Interface)] out IMFMediaType mediaType);
    [PreserveSig] int SetCurrentMediaType(uint streamIndex, IntPtr reserved, [MarshalAs(UnmanagedType.Interface)] IMFMediaType mediaType);
    [PreserveSig] int SetCurrentPosition(in Guid timeFormat, IntPtr position);
    [PreserveSig] int ReadSample(uint streamIndex, uint controlFlags, out uint actualStreamIndex, out uint streamFlags, out long timestamp, [MarshalAs(UnmanagedType.Interface)] out IMFSample? sample);
    [PreserveSig] int Flush(uint streamIndex);
    [PreserveSig] int GetServiceForStream(uint streamIndex, in Guid service, in Guid riid, out IntPtr value);
    [PreserveSig] int GetPresentationAttribute(uint streamIndex, in Guid attribute, IntPtr value);
}
