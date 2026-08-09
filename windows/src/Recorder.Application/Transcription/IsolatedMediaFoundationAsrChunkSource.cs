using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using Recorder.Core;
using TeamsRecorder.Windows.Application.AI;
using TeamsRecorder.Windows.Application.Storage;

namespace TeamsRecorder.Windows.Application.Transcription;

/// <summary>
/// Production Media Foundation ASR exporter. The decoder lives in a child
/// process because IMFSourceReader exposes synchronous Open/Read operations
/// with no reliable in-process cancellation contract.  Every worker response
/// has a hard deadline; cancellation or timeout kills the child before the
/// caller removes its private staging subtree.
/// </summary>
internal sealed class IsolatedMediaFoundationAsrChunkSource : IRecordingSessionAsrChunkSource
{
    // Decoding a full 120-second PCM chunk can be slower on low-end machines,
    // but it still has a finite upper bound so a wedged source-reader cannot
    // retain the foreground transcription job indefinitely.
    internal static readonly TimeSpan DefaultNoProgressTimeout = TimeSpan.FromSeconds(30);
    // The child kills immediately and waits at most one second for exit. Keep
    // the parent budget larger than that internal bound so it never abandons
    // teardown just before the process gets its kill/handle-close path.
    internal static readonly TimeSpan DefaultStopTimeout = TimeSpan.FromSeconds(3);
    private readonly IAsrWorkerProcessFactory workers;
    private readonly TimeSpan noProgressTimeout;
    private readonly TimeSpan stopTimeout;

    internal IsolatedMediaFoundationAsrChunkSource()
        : this(new ProcessAsrWorkerProcessFactory(), DefaultNoProgressTimeout, DefaultStopTimeout) { }

    internal IsolatedMediaFoundationAsrChunkSource(
        IAsrWorkerProcessFactory workers,
        TimeSpan? noProgressTimeout = null,
        TimeSpan? stopTimeout = null)
    {
        this.workers = workers ?? throw new ArgumentNullException(nameof(workers));
        this.noProgressTimeout = noProgressTimeout ?? DefaultNoProgressTimeout;
        this.stopTimeout = stopTimeout ?? DefaultStopTimeout;
        if (this.noProgressTimeout <= TimeSpan.Zero || this.stopTimeout <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(noProgressTimeout));
    }

    public async IAsyncEnumerable<RecordingSessionAsrChunk> ReadChunksAsync(
        RecordingSessionPlan plan,
        RecordingSessionAsrChunkConstraints constraints,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var media = RecordingSessionAsrMediaResolver.Resolve(plan);
        ValidateConstraints(constraints);
        cancellationToken.ThrowIfCancellationRequested();
        var staging = AsrWorkerStaging.Create(media.FolderPath);
        IAsrWorkerProcess? worker = null;
        try
        {
            worker = workers.Start(new AsrWorkerStartRequest(plan, media, constraints, staging));
            var ready = await ReadWithinDeadlineAsync(worker, cancellationToken).ConfigureAwait(false);
            if (ready.Kind != AsrWorkerMessageKind.Ready)
                throw new IOException("The isolated Media Foundation worker did not acknowledge a safe decoder startup.");

            var expectedSequence = 0;
            while (true)
            {
                var message = await ReadWithinDeadlineAsync(worker, cancellationToken).ConfigureAwait(false);
                if (message.Kind == AsrWorkerMessageKind.Completed)
                {
                    yield break;
                }
                if (message.Kind == AsrWorkerMessageKind.Failed)
                    throw new IOException("The isolated Media Foundation worker rejected the completed recording.");
                if (message.Kind != AsrWorkerMessageKind.Chunk || message.Sequence != expectedSequence ||
                    message.Duration <= TimeSpan.Zero || message.Duration > constraints.MaximumDuration ||
                    string.IsNullOrWhiteSpace(message.FileName) || Path.GetFileName(message.FileName) != message.FileName)
                    throw new IOException("The isolated Media Foundation worker produced an invalid chunk protocol message.");

                var chunkPath = AsrWorkerStaging.ResolveChunkPath(staging, message.FileName);
                byte[] audio;
                try
                {
                    audio = await ReadBoundedChunkAsync(chunkPath, constraints, cancellationToken).ConfigureAwait(false);
                }
                catch
                {
                    AsrWorkerStaging.DeleteFile(chunkPath);
                    throw;
                }

                try
                {
                    yield return new RecordingSessionAsrChunk(message.Sequence, message.Duration, audio, message.FileName);
                }
                finally
                {
                    AsrWorkerStaging.DeleteFile(chunkPath);
                    await AcknowledgeWithinDeadlineAsync(worker, cancellationToken).ConfigureAwait(false);
                }
                expectedSequence++;
            }
        }
        finally
        {
            if (worker is not null)
            {
                // Never await a potentially wedged child indefinitely. The real
                // worker implementation kills its process tree on this path;
                // the timeout here also keeps test doubles honest.
                try { await worker.StopAsync().WaitAsync(stopTimeout).ConfigureAwait(false); }
                catch (TimeoutException) { }
                catch (OperationCanceledException) { }
                catch (IOException) { }
                catch (InvalidOperationException) { }
            }
            AsrWorkerStaging.DeleteDirectory(staging);
        }
    }

    private async Task<AsrWorkerMessage> ReadWithinDeadlineAsync(IAsrWorkerProcess worker, CancellationToken cancellationToken)
    {
        try
        {
            return await worker.ReadAsync(cancellationToken).WaitAsync(noProgressTimeout, cancellationToken).ConfigureAwait(false);
        }
        catch (TimeoutException error)
        {
            throw new IOException($"Media Foundation ASR worker made no progress within {noProgressTimeout.TotalSeconds:0} seconds and was terminated.", error);
        }
    }

    private async Task AcknowledgeWithinDeadlineAsync(IAsrWorkerProcess worker, CancellationToken cancellationToken)
    {
        try
        {
            await worker.AcknowledgeAsync(cancellationToken).WaitAsync(noProgressTimeout, cancellationToken).ConfigureAwait(false);
        }
        catch (TimeoutException error)
        {
            throw new IOException($"Media Foundation ASR worker did not accept chunk acknowledgement within {noProgressTimeout.TotalSeconds:0} seconds and was terminated.", error);
        }
    }

    private static async Task<byte[]> ReadBoundedChunkAsync(string path, RecordingSessionAsrChunkConstraints constraints, CancellationToken cancellationToken)
    {
        AsrWorkerStaging.EnsureRegularFile(path);
        var length = new FileInfo(path).Length;
        if (length <= MediaFoundationRecordingSessionAsrChunkSource.WavHeaderBytes || length > constraints.MaximumBytes)
            throw new IOException("The isolated Media Foundation worker staged an oversized transcription chunk.");
        // The worker runs out-of-process, so re-check the exact byte limit
        // while reading. This deliberately allocates only one provider-sized
        // upload, never the completed recording or an attacker-grown file.
        var audio = GC.AllocateUninitializedArray<byte>(checked((int)length));
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        var offset = 0;
        while (offset < audio.Length)
        {
            var read = await stream.ReadAsync(audio.AsMemory(offset), cancellationToken).ConfigureAwait(false);
            if (read == 0)
                throw new IOException("The isolated Media Foundation worker staged a truncated transcription chunk.");
            offset += read;
        }
        if (stream.ReadByte() != -1 || !MediaFoundationRecordingSessionAsrChunkSource.IsCompletePcmWav(audio))
            throw new IOException("The isolated Media Foundation worker staged an invalid WAV chunk.");
        return audio;
    }

    private static void ValidateConstraints(RecordingSessionAsrChunkConstraints constraints)
    {
        ArgumentNullException.ThrowIfNull(constraints);
        if (constraints.MaximumDuration <= TimeSpan.Zero ||
            constraints.MaximumDuration > RecordingSessionAsrChunkConstraints.ProviderDefault.MaximumDuration ||
            constraints.MaximumBytes <= MediaFoundationRecordingSessionAsrChunkSource.WavHeaderBytes ||
            constraints.MaximumBytes > OpenAICompatibleAsrClient.MaximumAudioBytes)
            throw new ArgumentOutOfRangeException(nameof(constraints), "ASR chunk constraints exceed the supported provider limits.");
    }
}

internal enum AsrWorkerMessageKind { Ready, Chunk, Completed, Failed }
internal sealed record AsrWorkerMessage(AsrWorkerMessageKind Kind, int Sequence = 0, TimeSpan Duration = default, string? FileName = null);
internal sealed record AsrWorkerStartRequest(RecordingSessionPlan Plan, ResolvedRecordingSessionMedia Media, RecordingSessionAsrChunkConstraints Constraints, string StagingPath);

internal interface IAsrWorkerProcessFactory
{
    IAsrWorkerProcess Start(AsrWorkerStartRequest request);
}

internal interface IAsrWorkerProcess
{
    Task<AsrWorkerMessage> ReadAsync(CancellationToken cancellationToken);
    Task AcknowledgeAsync(CancellationToken cancellationToken);
    Task StopAsync();
}

internal sealed class ProcessAsrWorkerProcessFactory : IAsrWorkerProcessFactory
{
    public IAsrWorkerProcess Start(AsrWorkerStartRequest request)
    {
        var executable = ResolveExecutable();
        var start = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = AppContext.BaseDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = false,
        };
        // Do not inherit an automation host's duplicate PATH/Path entries.
        // The self-contained worker needs only Windows' core environment.
        start.Environment.Clear();
        CopyEnvironment(start, "SystemRoot");
        CopyEnvironment(start, "WINDIR");
        CopyEnvironment(start, "TEMP");
        CopyEnvironment(start, "TMP");
        CopyEnvironment(start, "USERPROFILE");
        CopyEnvironment(start, "LOCALAPPDATA");
        start.ArgumentList.Add("--asr-worker");
        start.ArgumentList.Add("--session"); start.ArgumentList.Add(request.Media.FolderPath);
        start.ArgumentList.Add("--kind"); start.ArgumentList.Add(((int)request.Plan.Kind).ToString(CultureInfo.InvariantCulture));
        start.ArgumentList.Add("--media"); start.ArgumentList.Add(request.Media.Path);
        start.ArgumentList.Add("--staging"); start.ArgumentList.Add(request.StagingPath);
        start.ArgumentList.Add("--duration-ticks"); start.ArgumentList.Add(request.Constraints.MaximumDuration.Ticks.ToString(CultureInfo.InvariantCulture));
        start.ArgumentList.Add("--maximum-bytes"); start.ArgumentList.Add(request.Constraints.MaximumBytes.ToString(CultureInfo.InvariantCulture));
        Process? process;
        try { process = Process.Start(start); }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            throw new IOException("The isolated Media Foundation worker could not be started.", error);
        }
        if (process is null) throw new IOException("The isolated Media Foundation worker could not be started.");
        return new ProcessAsrWorkerProcess(process);
    }

    private static void CopyEnvironment(ProcessStartInfo start, string name)
    {
        var value = Environment.GetEnvironmentVariable(name);
        if (!string.IsNullOrWhiteSpace(value)) start.Environment[name] = value;
    }

    private static string ResolveExecutable()
    {
        var baseDirectory = Path.GetFullPath(AppContext.BaseDirectory);
        var candidate = Path.GetFullPath(Path.Combine(baseDirectory, "Recorder.AsrWorker.exe"));
        if (!candidate.StartsWith(baseDirectory.EndsWith(Path.DirectorySeparatorChar) ? baseDirectory : baseDirectory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
            !File.Exists(candidate))
            throw new IOException("The isolated Media Foundation worker is unavailable in this installation.");
        var attributes = File.GetAttributes(candidate);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException("The isolated Media Foundation worker path is unsafe.");
        return candidate;
    }
}

internal sealed class ProcessAsrWorkerProcess : IAsrWorkerProcess
{
    private static readonly TimeSpan GracefulExit = TimeSpan.FromSeconds(1);
    private readonly Process process;
    private readonly StreamWriter input;
    private readonly StreamReader output;
    private int stopped;

    public ProcessAsrWorkerProcess(Process process)
    {
        this.process = process;
        input = process.StandardInput;
        output = process.StandardOutput;
    }

    public async Task<AsrWorkerMessage> ReadAsync(CancellationToken cancellationToken)
    {
        var line = await output.ReadLineAsync(cancellationToken).ConfigureAwait(false);
        if (line is null) throw new IOException("The isolated Media Foundation worker exited without a protocol response.");
        return AsrWorkerProtocol.Parse(line);
    }

    public async Task AcknowledgeAsync(CancellationToken cancellationToken)
    {
        await input.WriteLineAsync(AsrWorkerProtocol.Acknowledge.AsMemory(), cancellationToken).ConfigureAwait(false);
        await input.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task StopAsync()
    {
        if (Interlocked.Exchange(ref stopped, 1) != 0) return;
        try
        {
            // Do not try a graceful stdin command here. A child that is stuck
            // inside MFCreateSourceReaderFromURL/ReadSample might never drain
            // that pipe, whereas Kill is independent of the COM call. The
            // parent has already decided that its consumer is done.
            if (!TryHasExited())
            {
                try { process.Kill(entireProcessTree: true); }
                catch (InvalidOperationException) { }
                catch (System.ComponentModel.Win32Exception) { }
                try { await process.WaitForExitAsync().WaitAsync(GracefulExit).ConfigureAwait(false); }
                catch (TimeoutException) { }
                catch (InvalidOperationException) { }
            }
        }
        finally
        {
            input.Dispose();
            output.Dispose();
            process.Dispose();
        }
    }

    private bool TryHasExited()
    {
        try { return process.HasExited; }
        catch (InvalidOperationException) { return true; }
    }
}

internal static class AsrWorkerProtocol
{
    internal const string Acknowledge = "ACK";
    private const int MaximumLineLength = 512;

    public static AsrWorkerMessage Parse(string line)
    {
        if (line is null || line.Length == 0 || line.Length > MaximumLineLength || line.IndexOfAny(['\r', '\n']) >= 0)
            throw new IOException("The isolated Media Foundation worker sent an invalid protocol response.");
        if (line == "READY") return new(AsrWorkerMessageKind.Ready);
        if (line == "COMPLETE") return new(AsrWorkerMessageKind.Completed);
        if (line == "FAILED") return new(AsrWorkerMessageKind.Failed);
        var parts = line.Split('\t');
        if (parts.Length != 4 || parts[0] != "CHUNK" ||
            !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var sequence) || sequence < 0 ||
            !long.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out var ticks) || ticks <= 0 ||
            !IsSafeFileName(parts[3]))
            throw new IOException("The isolated Media Foundation worker sent an invalid chunk response.");
        return new(AsrWorkerMessageKind.Chunk, sequence, TimeSpan.FromTicks(ticks), parts[3]);
    }

    public static string Chunk(int sequence, TimeSpan duration, string fileName)
    {
        if (sequence < 0 || duration <= TimeSpan.Zero || !IsSafeFileName(fileName)) throw new ArgumentOutOfRangeException(nameof(fileName));
        return $"CHUNK\t{sequence}\t{duration.Ticks}\t{fileName}";
    }

    public static bool IsSafeFileName(string? value) =>
        !string.IsNullOrWhiteSpace(value) && value.Length <= 128 && Path.GetFileName(value) == value &&
        value.EndsWith(".wav", StringComparison.OrdinalIgnoreCase) && value.All(character => char.IsAsciiLetterOrDigit(character) || character is '.' or '-' or '_');
}

internal static class AsrWorkerStaging
{
    private const string Prefix = ".asr-worker-";

    public static string Create(string sessionFolder)
    {
        var folder = Path.GetFullPath(sessionFolder);
        EnsureDirectory(folder);
        CleanupStaleWorkerDirectories(folder);
        var staging = Path.Combine(folder, Prefix + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        EnsureDirectory(staging);
        return staging;
    }

    public static void ValidateWorkerStaging(string sessionFolder, string staging)
    {
        var folder = Path.GetFullPath(sessionFolder);
        var candidate = Path.GetFullPath(staging);
        EnsureDirectory(folder);
        if (!string.Equals(Path.GetDirectoryName(candidate), folder, StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFileName(candidate).StartsWith(Prefix, StringComparison.Ordinal) ||
            !Guid.TryParseExact(Path.GetFileName(candidate)[Prefix.Length..], "N", out _))
            throw new IOException("The ASR worker staging path is not an owned direct child of the session.");
        EnsureDirectory(candidate);
    }

    public static string ResolveChunkPath(string staging, string fileName)
    {
        if (!AsrWorkerProtocol.IsSafeFileName(fileName)) throw new IOException("The ASR worker chunk file name is unsafe.");
        var root = Path.GetFullPath(staging);
        EnsureDirectory(root);
        var path = Path.GetFullPath(Path.Combine(root, fileName));
        if (!path.StartsWith(root.EndsWith(Path.DirectorySeparatorChar) ? root : root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("The ASR worker chunk path escapes its staging directory.");
        return path;
    }

    public static void EnsureRegularFile(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException("The ASR worker chunk is not a safe regular file.");
    }

    public static void DeleteFile(string path)
    {
        if (!File.Exists(path)) return;
        EnsureRegularFile(path);
        File.Delete(path);
    }

    public static void DeleteDirectory(string staging)
    {
        // The killed worker can still be releasing file handles for a moment.
        // Cleanup is intentionally bounded/best-effort here; a later request
        // removes only stale, owned direct children. Most importantly, this
        // path never waits for a wedged MF COM call in the child process.
        try
        {
            if (!Directory.Exists(staging)) return;
            EnsureDirectory(staging);
            Directory.Delete(staging, recursive: true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void CleanupStaleWorkerDirectories(string sessionFolder)
    {
        var earliest = DateTime.UtcNow - TimeSpan.FromHours(24);
        foreach (var candidate in Directory.EnumerateDirectories(sessionFolder, Prefix + "*", SearchOption.TopDirectoryOnly))
        {
            try
            {
                var name = Path.GetFileName(candidate);
                var attributes = File.GetAttributes(candidate);
                if (!name.StartsWith(Prefix, StringComparison.Ordinal) ||
                    !Guid.TryParseExact(name[Prefix.Length..], "N", out _) ||
                    (attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != FileAttributes.Directory ||
                    new DirectoryInfo(candidate).CreationTimeUtc >= earliest)
                    continue;
                Directory.Delete(candidate, recursive: true);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static void EnsureDirectory(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != FileAttributes.Directory)
            throw new IOException("The ASR worker staging directory is unsafe.");
    }
}

/// <summary>Child-process entry point. It uses stdin/stdout only for a bounded
/// private protocol; audio itself remains in the parent-created staging folder.</summary>
internal static class MediaFoundationAsrWorkerHost
{
    public static async Task<int> RunAsync(string[] arguments, TextReader input, TextWriter output, CancellationToken cancellationToken)
    {
        if (!TryParse(arguments, out var request)) return 2;
        try
        {
            AsrWorkerStaging.ValidateWorkerStaging(request.SessionFolder, request.StagingPath);
            var plan = new RecordingSessionPlan(request.Kind, request.SessionFolder, request.MediaPath,
                Path.Combine(request.SessionFolder, RecordingSessionLayout.BackupAudioFileName),
                Path.Combine(request.SessionFolder, RecordingSessionLayout.MetadataFileName),
                new StorageCapacityStatus(null, RecordingStorageDecision.Normal));
            var media = RecordingSessionAsrMediaResolver.Resolve(plan);
            if (!string.Equals(media.Path, Path.GetFullPath(request.MediaPath), StringComparison.OrdinalIgnoreCase))
                throw new IOException("The ASR worker media path is not the canonical completed recording.");
            await WriteAsync(output, "READY", cancellationToken).ConfigureAwait(false);
            var source = new MediaFoundationRecordingSessionAsrChunkSource(new MediaFoundationPcmReaderFactory(), request.StagingPath);
            await foreach (var chunk in source.ReadChunksAsync(plan, request.Constraints, cancellationToken).ConfigureAwait(false))
            {
                var path = AsrWorkerStaging.ResolveChunkPath(request.StagingPath, chunk.FileName);
                await WriteChunkAsync(path, chunk.Audio, request.Constraints.MaximumBytes, cancellationToken).ConfigureAwait(false);
                await WriteAsync(output, AsrWorkerProtocol.Chunk(chunk.Sequence, chunk.Duration, chunk.FileName), cancellationToken).ConfigureAwait(false);
                var acknowledgement = await input.ReadLineAsync(cancellationToken).ConfigureAwait(false);
                if (!string.Equals(acknowledgement, AsrWorkerProtocol.Acknowledge, StringComparison.Ordinal))
                    return 3;
                AsrWorkerStaging.DeleteFile(path);
            }
            await WriteAsync(output, "COMPLETE", cancellationToken).ConfigureAwait(false);
            return 0;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return 3;
        }
        catch
        {
            try { await WriteAsync(output, "FAILED", CancellationToken.None).ConfigureAwait(false); } catch (IOException) { }
            return 1;
        }
    }

    private static async Task WriteChunkAsync(string path, byte[] audio, int maximumBytes, CancellationToken cancellationToken)
    {
        if (audio.Length <= MediaFoundationRecordingSessionAsrChunkSource.WavHeaderBytes || audio.Length > maximumBytes ||
            !MediaFoundationRecordingSessionAsrChunkSource.IsCompletePcmWav(audio))
            throw new IOException("The ASR worker refused an invalid bounded WAV chunk.");
        await using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024,
            FileOptions.SequentialScan | FileOptions.WriteThrough);
        await stream.WriteAsync(audio, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async Task WriteAsync(TextWriter output, string line, CancellationToken cancellationToken)
    {
        await output.WriteLineAsync(line.AsMemory(), cancellationToken).ConfigureAwait(false);
        await output.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static bool TryParse(string[] arguments, out WorkerArguments request)
    {
        request = default;
        if (arguments is null || arguments.Length != 13 || arguments[0] != "--asr-worker") return false;
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 1; index < arguments.Length; index += 2)
        {
            var key = arguments[index];
            var value = arguments[index + 1];
            if (string.IsNullOrWhiteSpace(key) || string.IsNullOrWhiteSpace(value) || !values.TryAdd(key, value)) return false;
        }
        if (!values.TryGetValue("--session", out var session) || !values.TryGetValue("--kind", out var kindText) ||
            !values.TryGetValue("--media", out var media) || !values.TryGetValue("--staging", out var staging) ||
            !values.TryGetValue("--duration-ticks", out var durationText) || !values.TryGetValue("--maximum-bytes", out var bytesText) ||
            !int.TryParse(kindText, NumberStyles.None, CultureInfo.InvariantCulture, out var kindValue) || !Enum.IsDefined(typeof(RecordingSessionKind), kindValue) ||
            !long.TryParse(durationText, NumberStyles.None, CultureInfo.InvariantCulture, out var ticks) || ticks <= 0 ||
            !int.TryParse(bytesText, NumberStyles.None, CultureInfo.InvariantCulture, out var bytes) || bytes <= 0)
            return false;
        try
        {
            request = new WorkerArguments(Path.GetFullPath(session), (RecordingSessionKind)kindValue, Path.GetFullPath(media), Path.GetFullPath(staging),
                new RecordingSessionAsrChunkConstraints(TimeSpan.FromTicks(ticks), bytes));
            return true;
        }
        catch (ArgumentException) { return false; }
        catch (OverflowException) { return false; }
    }

    private readonly record struct WorkerArguments(string SessionFolder, RecordingSessionKind Kind, string MediaPath, string StagingPath, RecordingSessionAsrChunkConstraints Constraints);
}
