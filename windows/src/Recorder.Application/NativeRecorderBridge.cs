using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace TeamsRecorder.Windows.Application;

public sealed class NativeRecorderInteropException : Exception
{
    public NativeRecorderInteropException(string message)
        : base(message)
    {
    }
}

public sealed partial class NativeRecorderBridge : INativeRecorderBridge, INativeRecorderMicrophoneMuteControl, INativeSelectedAudioRecorderBridge, INativeSelectedWindowAvRecorderBridge, INativeTeamsRenderEndpointProbe
{
    private const string RequiredAbiVersion = "0.8.0";
    private readonly object gate = new();
    private readonly NativeBridgeHandle handle;
    private bool disposed;

    public NativeRecorderBridge()
    {
        if (!OperatingSystem.IsWindows() ||
            RuntimeInformation.ProcessArchitecture != Architecture.X64)
        {
            throw new NativeRecorderInteropException(
                "The Windows native recorder bridge currently supports only x64 hosts.");
        }

        EnsureStructLayouts();
        EnsureCompatibleVersion();

        var nativeHandle = NativeMethods.Create();
        if (nativeHandle == IntPtr.Zero)
        {
            throw new NativeRecorderInteropException("Creating the native audio bridge failed.");
        }

        handle = NativeBridgeHandle.FromOwned(nativeHandle);
    }

    public NativeOperationResult Start(NativeRecordingRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();

        lock (gate)
        {
            ThrowIfDisposed();
            var outputPath = Marshal.StringToCoTaskMemUTF8(request.OutputPath);
            var endpointId = string.IsNullOrEmpty(request.EndpointId)
                ? IntPtr.Zero
                : Marshal.StringToCoTaskMemUTF8(request.EndpointId);
            try
            {
                var options = new NativeStartOptions
                {
                    StructSize = checked((uint)Marshal.SizeOf<NativeStartOptions>()),
                    Mode = request.Mode,
                    OutputPathUtf8 = outputPath,
                    EndpointIdUtf8 = endpointId,
                    TargetProcessId = request.TargetProcessId,
                    Reserved = 0,
                };
                return ToOperationResult(NativeMethods.StartWithOptions(handle, ref options));
            }
            finally
            {
                Marshal.FreeCoTaskMem(outputPath);
                Marshal.FreeCoTaskMem(endpointId);
            }
        }
    }

    public NativeOperationResult StartMixed(NativeMixedRecordingRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();

        lock (gate)
        {
            ThrowIfDisposed();
            var outputPath = Marshal.StringToCoTaskMemUTF8(request.OutputPath);
            var renderEndpointId = string.IsNullOrEmpty(request.RenderEndpointId)
                ? IntPtr.Zero
                : Marshal.StringToCoTaskMemUTF8(request.RenderEndpointId);
            var microphoneEndpointId = string.IsNullOrEmpty(request.MicrophoneEndpointId)
                ? IntPtr.Zero
                : Marshal.StringToCoTaskMemUTF8(request.MicrophoneEndpointId);
            try
            {
                var options = new NativeMixedStartOptions
                {
                    StructSize = checked((uint)Marshal.SizeOf<NativeMixedStartOptions>()),
                    OutputPathUtf8 = outputPath,
                    RenderEndpointIdUtf8 = renderEndpointId,
                    MicrophoneEndpointIdUtf8 = microphoneEndpointId,
                    AacBitRateBps = request.AacBitRate,
                    Reserved = 0,
                };
                return ToOperationResult(NativeMethods.StartMixed(handle, ref options));
            }
            finally
            {
                Marshal.FreeCoTaskMem(outputPath);
                Marshal.FreeCoTaskMem(renderEndpointId);
                Marshal.FreeCoTaskMem(microphoneEndpointId);
            }
        }
    }

    public NativeOperationResult StartSelectedAudio(NativeSelectedAudioRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();

        lock (gate)
        {
            ThrowIfDisposed();
            var outputPath = Marshal.StringToCoTaskMemUTF8(request.OutputPath);
            var renderEndpointId = string.IsNullOrEmpty(request.RenderEndpointId)
                ? IntPtr.Zero
                : Marshal.StringToCoTaskMemUTF8(request.RenderEndpointId);
            var microphoneEndpointId = string.IsNullOrEmpty(request.MicrophoneEndpointId)
                ? IntPtr.Zero
                : Marshal.StringToCoTaskMemUTF8(request.MicrophoneEndpointId);
            try
            {
                var options = new NativeSelectedAudioStartOptions
                {
                    StructSize = checked((uint)Marshal.SizeOf<NativeSelectedAudioStartOptions>()),
                    AudioSource = request.AudioSource,
                    OutputPathUtf8 = outputPath,
                    RenderEndpointIdUtf8 = renderEndpointId,
                    MicrophoneEndpointIdUtf8 = microphoneEndpointId,
                    TargetProcessId = request.TargetProcessId,
                    IncludedProcessTree = request.IncludedProcessTree ? 1U : 0U,
                    AacBitRateBps = request.AacBitRate,
                    Reserved = 0,
                    ExpectedProcessCreationTime100Nanoseconds = request.ExpectedProcessCreationTime100Nanoseconds,
                };
                return ToOperationResult(NativeMethods.StartSelectedAudio(handle, ref options));
            }
            finally
            {
                Marshal.FreeCoTaskMem(outputPath);
                Marshal.FreeCoTaskMem(renderEndpointId);
                Marshal.FreeCoTaskMem(microphoneEndpointId);
            }
        }
    }

    public NativeOperationResult StartSelectedWindowAv(NativeSelectedWindowAvRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();
        lock (gate)
        {
            ThrowIfDisposed();
            var audioPath = Marshal.StringToCoTaskMemUTF8(request.AudioRecoveryPath);
            var videoPath = Marshal.StringToCoTaskMemUTF8(request.VideoOutputPath);
            var render = string.IsNullOrEmpty(request.RenderEndpointId) ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(request.RenderEndpointId);
            var microphone = string.IsNullOrEmpty(request.MicrophoneEndpointId) ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(request.MicrophoneEndpointId);
            try
            {
                var options = new NativeSelectedWindowAvStartOptions
                {
                    StructSize = checked((uint)Marshal.SizeOf<NativeSelectedWindowAvStartOptions>()),
                    AudioSource = request.AudioSource,
                    AudioOutputPathUtf8 = audioPath,
                    VideoOutputPathUtf8 = videoPath,
                    RenderEndpointIdUtf8 = render,
                    MicrophoneEndpointIdUtf8 = microphone,
                    TargetWindowHandle = unchecked((ulong)request.WindowTarget.WindowHandle.ToInt64()),
                    TargetWindowProcessId = checked((uint)request.WindowTarget.ProcessId),
                    AudioTargetProcessId = request.AudioTargetProcessId,
                    IncludedProcessTree = request.IncludedProcessTree ? 1U : 0U,
                    VideoWidth = request.VideoWidth,
                    VideoHeight = request.VideoHeight,
                    VideoFrameRate = request.VideoFrameRate,
                    VideoBitRateBps = request.VideoBitRate,
                    AacBitRateBps = request.AacBitRate,
                    Reserved = 0,
                    AudioProcessCreationTime100Nanoseconds = request.AudioProcessCreationTime100Nanoseconds,
                    TargetWindowProcessCreationTime100Nanoseconds = checked((ulong)request.WindowTarget.ProcessCreationTimeFileTimeUtc),
                };
                return ToOperationResult(NativeMethods.StartSelectedWindowAv(handle, ref options));
            }
            finally
            {
                Marshal.FreeCoTaskMem(audioPath);
                Marshal.FreeCoTaskMem(videoPath);
                Marshal.FreeCoTaskMem(render);
                Marshal.FreeCoTaskMem(microphone);
            }
        }
    }

    public NativeOperationResult Stop()
    {
        lock (gate)
        {
            ThrowIfDisposed();
            return ToOperationResult(NativeMethods.Stop(handle));
        }
    }

    public NativeOperationResult SetMicrophoneMuted(bool muted)
    {
        lock (gate)
        {
            ThrowIfDisposed();
            return ToOperationResult(NativeMethods.SetMicrophoneMuted(handle, muted ? 1U : 0U));
        }
    }

    public NativeRecorderSnapshot GetSnapshot()
    {
        lock (gate)
        {
            ThrowIfDisposed();
            var stats = new NativeStats
            {
                StructSize = checked((uint)Marshal.SizeOf<NativeStats>()),
            };
            var result = NativeMethods.GetStats(handle, ref stats);
            var state = NativeMethods.GetState(handle);
            var error = result == NativeRecorderResult.Ok
                ? NormalizeError(ReadLastErrorLocked())
                : ErrorOrFallback(ReadLastErrorLocked(), "The native audio bridge could not read capture statistics.");
            return new NativeRecorderSnapshot(
                result,
                state,
                ToManagedStats(stats),
                error);
        }
    }

    public NativeEndpointEnumerationResult EnumerateEndpoints()
    {
        lock (gate)
        {
            ThrowIfDisposed();
            var result = NativeMethods.EnumerateEndpoints(handle, out var rawList);
            if (result != NativeRecorderResult.Ok)
            {
                return new NativeEndpointEnumerationResult(
                    ToOperationResult(result),
                    Array.Empty<NativeCaptureEndpoint>());
            }

            if (rawList == IntPtr.Zero)
            {
                return new NativeEndpointEnumerationResult(
                    NativeOperationResult.Failure(
                        NativeRecorderResult.InternalError,
                        "The native audio bridge returned an empty endpoint snapshot."),
                    Array.Empty<NativeCaptureEndpoint>());
            }

            using var list = NativeEndpointListHandle.FromOwned(rawList);
            var countResult = NativeMethods.GetEndpointCount(list, out var count);
            if (countResult != NativeRecorderResult.Ok)
            {
                return new NativeEndpointEnumerationResult(
                    NativeOperationResult.Failure(
                        countResult,
                        "The native audio bridge returned an invalid endpoint snapshot."),
                    Array.Empty<NativeCaptureEndpoint>());
            }

            const uint maximumEndpointCount = 4_096;
            if (count > maximumEndpointCount)
            {
                return new NativeEndpointEnumerationResult(
                    NativeOperationResult.Failure(
                        NativeRecorderResult.InternalError,
                        "The native audio bridge returned too many audio endpoints."),
                    Array.Empty<NativeCaptureEndpoint>());
            }

            var endpoints = new List<NativeCaptureEndpoint>(checked((int)count));
            var addedReference = false;
            list.DangerousAddRef(ref addedReference);
            try
            {
                for (uint index = 0; index < count; index++)
                {
                    var itemResult = NativeMethods.GetEndpoint(
                        list,
                        index,
                        out var flow,
                        out var defaultRoles,
                        out var endpointId,
                        out var friendlyName);
                    if (itemResult != NativeRecorderResult.Ok)
                    {
                        return new NativeEndpointEnumerationResult(
                            NativeOperationResult.Failure(
                                itemResult,
                                "The native audio bridge returned an invalid endpoint entry."),
                            Array.Empty<NativeCaptureEndpoint>());
                    }

                    var copiedEndpointId = Marshal.PtrToStringUTF8(endpointId);
                    var copiedFriendlyName = Marshal.PtrToStringUTF8(friendlyName);
                    if (string.IsNullOrEmpty(copiedEndpointId) || copiedFriendlyName is null)
                    {
                        return new NativeEndpointEnumerationResult(
                            NativeOperationResult.Failure(
                                NativeRecorderResult.InternalError,
                                "The native audio bridge returned an endpoint with missing text."),
                            Array.Empty<NativeCaptureEndpoint>());
                    }

                    if (flow is not CaptureEndpointFlow.Render and not CaptureEndpointFlow.Capture)
                    {
                        return new NativeEndpointEnumerationResult(
                            NativeOperationResult.Failure(
                                NativeRecorderResult.InternalError,
                                "The native audio bridge returned an endpoint with an unknown flow."),
                            Array.Empty<NativeCaptureEndpoint>());
                    }

                    endpoints.Add(new NativeCaptureEndpoint(
                        flow,
                        (EndpointDefaultRole)defaultRoles,
                        copiedEndpointId,
                        copiedFriendlyName));
                }
            }
            finally
            {
                if (addedReference)
                {
                    list.DangerousRelease();
                }
            }

            return new NativeEndpointEnumerationResult(
                NativeOperationResult.Success(),
                endpoints.AsReadOnly());
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            handle.Dispose();
        }
    }

    private static void EnsureStructLayouts()
    {
        if (Marshal.SizeOf<NativeStartOptions>() != 32 ||
            Marshal.SizeOf<NativeMixedStartOptions>() != 40 ||
            Marshal.SizeOf<NativeSelectedAudioStartOptions>() != 56 ||
            Marshal.SizeOf<NativeSelectedWindowAvStartOptions>() != 104 ||
            Marshal.SizeOf<NativeStats>() != 208)
        {
            throw new NativeRecorderInteropException(
                "The managed native-bridge layouts do not match the x64 C ABI.");
        }
    }

    private static void EnsureCompatibleVersion()
    {
        var version = Marshal.PtrToStringUTF8(NativeMethods.Version());
        if (!Version.TryParse(version, out var parsedVersion) ||
            parsedVersion is null ||
            parsedVersion.Major != 0 ||
            parsedVersion.CompareTo(new Version(0, 8)) < 0)
        {
            throw new NativeRecorderInteropException(
                $"Recorder.NativeBridge {RequiredAbiVersion} or newer is required.");
        }
    }

    private NativeOperationResult ToOperationResult(NativeRecorderResult result) =>
        result == NativeRecorderResult.Ok
            ? NativeOperationResult.Success()
            : NativeOperationResult.Failure(result, NormalizeError(ReadLastErrorLocked()));

    private string? ReadLastErrorLocked()
    {
        var addedReference = false;
        handle.DangerousAddRef(ref addedReference);
        try
        {
            return Marshal.PtrToStringUTF8(NativeMethods.GetLastError(handle));
        }
        finally
        {
            if (addedReference)
            {
                handle.DangerousRelease();
            }
        }
    }

    private static NativeCaptureStats ToManagedStats(NativeStats stats) => new(
        stats.Mode,
        stats.SourceSampleRate,
        stats.SourceChannels,
        stats.OutputSampleRate,
        stats.OutputChannels,
        stats.EventDriven != 0,
        stats.Packets,
        stats.InputFrames,
        stats.OutputFrames,
        stats.SilentPackets,
        stats.Discontinuities,
        stats.FirstQpc100Nanoseconds,
        stats.LastQpc100Nanoseconds,
        stats.Peak,
        new NativeSourceTimelineStats(
            stats.RenderDriftCorrections, stats.RenderLatePackets,
            stats.RenderLateFramesDropped, stats.RenderQueueOverflows,
            stats.RenderSourceDisconnects, stats.RenderDiscontinuities),
        new NativeSourceTimelineStats(
            stats.MicrophoneDriftCorrections, stats.MicrophoneLatePackets,
            stats.MicrophoneLateFramesDropped, stats.MicrophoneQueueOverflows,
            stats.MicrophoneSourceDisconnects, stats.MicrophoneDiscontinuities))
    {
        PrimaryLevelPeak = stats.PrimaryLevelPeak,
        PrimaryLevelRms = stats.PrimaryLevelRms,
        MicrophoneLevelPeak = stats.MicrophoneLevelPeak,
        MicrophoneLevelRms = stats.MicrophoneLevelRms,
    };

    private static string? NormalizeError(string? error) =>
        string.IsNullOrWhiteSpace(error) ? null : error;

    private static string ErrorOrFallback(string? error, string fallback) =>
        NormalizeError(error) ?? fallback;

    private void ThrowIfDisposed()
    {
        if (disposed)
        {
            throw new ObjectDisposedException(nameof(NativeRecorderBridge));
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct NativeStartOptions
    {
        public uint StructSize;
        public RecordingCaptureMode Mode;
        public IntPtr OutputPathUtf8;
        public IntPtr EndpointIdUtf8;
        public uint TargetProcessId;
        public uint Reserved;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct NativeMixedStartOptions
    {
        public uint StructSize;
        public IntPtr OutputPathUtf8;
        public IntPtr RenderEndpointIdUtf8;
        public IntPtr MicrophoneEndpointIdUtf8;
        public uint AacBitRateBps;
        public uint Reserved;
    }

    public NativeTeamsRenderEndpointProbeResult ProbeTeamsRenderEndpoints()
    {
        lock (gate)
        {
            ThrowIfDisposed();
            NativeRecorderResult result;
            IntPtr rawList;
            try
            {
                result = NativeMethods.ProbeTeamsRenderEndpoints(handle, out rawList);
            }
            catch (EntryPointNotFoundException)
            {
                return new NativeTeamsRenderEndpointProbeResult(
                    NativeOperationResult.Failure(
                        NativeRecorderResult.NotImplemented,
                        "The installed native recorder bridge does not support the Teams playback endpoint preflight."),
                    Array.Empty<NativeCaptureEndpoint>());
            }
            if (result != NativeRecorderResult.Ok)
            {
                return new NativeTeamsRenderEndpointProbeResult(
                    ToOperationResult(result),
                    Array.Empty<NativeCaptureEndpoint>());
            }

            if (rawList == IntPtr.Zero)
            {
                return new NativeTeamsRenderEndpointProbeResult(
                    NativeOperationResult.Failure(
                        NativeRecorderResult.InternalError,
                        "The native audio bridge returned an empty Teams render-session snapshot."),
                    Array.Empty<NativeCaptureEndpoint>());
            }

            using var list = NativeEndpointListHandle.FromOwned(rawList);
            var countResult = NativeMethods.GetEndpointCount(list, out var count);
            if (countResult != NativeRecorderResult.Ok || count > 4_096)
            {
                return new NativeTeamsRenderEndpointProbeResult(
                    NativeOperationResult.Failure(
                        countResult == NativeRecorderResult.Ok ? NativeRecorderResult.InternalError : countResult,
                        "The native audio bridge returned an invalid Teams render-session snapshot."),
                    Array.Empty<NativeCaptureEndpoint>());
            }

            var endpoints = new List<NativeCaptureEndpoint>(checked((int)count));
            var addedReference = false;
            list.DangerousAddRef(ref addedReference);
            try
            {
                for (uint index = 0; index < count; index++)
                {
                    var itemResult = NativeMethods.GetEndpoint(
                        list, index, out var flow, out var defaultRoles, out var endpointId, out var friendlyName);
                    var copiedEndpointId = Marshal.PtrToStringUTF8(endpointId);
                    var copiedFriendlyName = Marshal.PtrToStringUTF8(friendlyName);
                    if (itemResult != NativeRecorderResult.Ok ||
                        flow != CaptureEndpointFlow.Render ||
                        string.IsNullOrEmpty(copiedEndpointId) || copiedFriendlyName is null)
                    {
                        return new NativeTeamsRenderEndpointProbeResult(
                            NativeOperationResult.Failure(
                                itemResult == NativeRecorderResult.Ok ? NativeRecorderResult.InternalError : itemResult,
                                "The native audio bridge returned an invalid Teams render-session endpoint."),
                            Array.Empty<NativeCaptureEndpoint>());
                    }
                    endpoints.Add(new NativeCaptureEndpoint(flow, (EndpointDefaultRole)defaultRoles,
                        copiedEndpointId, copiedFriendlyName));
                }
            }
            finally
            {
                if (addedReference)
                {
                    list.DangerousRelease();
                }
            }

            return new NativeTeamsRenderEndpointProbeResult(
                NativeOperationResult.Success(), endpoints.AsReadOnly());
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct NativeSelectedAudioStartOptions
    {
        public uint StructSize;
        public NativeSelectedAudioSource AudioSource;
        public IntPtr OutputPathUtf8;
        public IntPtr RenderEndpointIdUtf8;
        public IntPtr MicrophoneEndpointIdUtf8;
        public uint TargetProcessId;
        public uint IncludedProcessTree;
        public uint AacBitRateBps;
        public uint Reserved;
        public ulong ExpectedProcessCreationTime100Nanoseconds;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct NativeSelectedWindowAvStartOptions
    {
        public uint StructSize;
        public NativeSelectedAudioSource AudioSource;
        public IntPtr AudioOutputPathUtf8;
        public IntPtr VideoOutputPathUtf8;
        public IntPtr RenderEndpointIdUtf8;
        public IntPtr MicrophoneEndpointIdUtf8;
        public ulong TargetWindowHandle;
        public uint TargetWindowProcessId;
        public uint AudioTargetProcessId;
        public uint IncludedProcessTree;
        public uint VideoWidth;
        public uint VideoHeight;
        public uint VideoFrameRate;
        public uint VideoBitRateBps;
        public uint AacBitRateBps;
        public uint Reserved;
        public ulong AudioProcessCreationTime100Nanoseconds;
        public ulong TargetWindowProcessCreationTime100Nanoseconds;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct NativeStats
    {
        public uint StructSize;
        public RecordingCaptureMode Mode;
        public uint SourceSampleRate;
        public uint SourceChannels;
        public uint OutputSampleRate;
        public uint OutputChannels;
        public uint EventDriven;
        public uint Reserved;
        public ulong Packets;
        public ulong InputFrames;
        public ulong OutputFrames;
        public ulong SilentPackets;
        public ulong Discontinuities;
        public ulong FirstQpc100Nanoseconds;
        public ulong LastQpc100Nanoseconds;
        public float Peak;
        public ulong RenderDriftCorrections;
        public ulong RenderLatePackets;
        public ulong RenderLateFramesDropped;
        public ulong RenderQueueOverflows;
        public ulong RenderSourceDisconnects;
        public ulong RenderDiscontinuities;
        public ulong MicrophoneDriftCorrections;
        public ulong MicrophoneLatePackets;
        public ulong MicrophoneLateFramesDropped;
        public ulong MicrophoneQueueOverflows;
        public ulong MicrophoneSourceDisconnects;
        public ulong MicrophoneDiscontinuities;
        public float PrimaryLevelPeak;
        public float PrimaryLevelRms;
        public float MicrophoneLevelPeak;
        public float MicrophoneLevelRms;
    }

    private sealed class NativeBridgeHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        private NativeBridgeHandle()
            : base(ownsHandle: true)
        {
        }

        public static NativeBridgeHandle FromOwned(IntPtr value)
        {
            var result = new NativeBridgeHandle();
            result.SetHandle(value);
            return result;
        }

        protected override bool ReleaseHandle()
        {
            try
            {
                NativeMethods.Destroy(handle);
                return true;
            }
            catch
            {
                return false;
            }
        }
    }

    private sealed class NativeEndpointListHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        private NativeEndpointListHandle()
            : base(ownsHandle: true)
        {
        }

        public static NativeEndpointListHandle FromOwned(IntPtr value)
        {
            var result = new NativeEndpointListHandle();
            result.SetHandle(value);
            return result;
        }

        protected override bool ReleaseHandle()
        {
            try
            {
                NativeMethods.DestroyEndpointList(handle);
                return true;
            }
            catch
            {
                return false;
            }
        }
    }

    private static partial class NativeMethods
    {
        private const string LibraryName = "Recorder.NativeBridge";

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_create")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial IntPtr Create();

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_destroy")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial void Destroy(IntPtr bridge);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_start_with_options")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeRecorderResult StartWithOptions(
            NativeBridgeHandle bridge,
            ref NativeStartOptions options);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_start_mixed")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeRecorderResult StartMixed(
            NativeBridgeHandle bridge,
            ref NativeMixedStartOptions options);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_start_selected_audio")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeRecorderResult StartSelectedAudio(
            NativeBridgeHandle bridge,
            ref NativeSelectedAudioStartOptions options);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_start_selected_window_av")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeRecorderResult StartSelectedWindowAv(
            NativeBridgeHandle bridge,
            ref NativeSelectedWindowAvStartOptions options);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_set_microphone_muted")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeRecorderResult SetMicrophoneMuted(
            NativeBridgeHandle bridge,
            uint muted);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_stop")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeRecorderResult Stop(NativeBridgeHandle bridge);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_get_state")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeRecorderState GetState(NativeBridgeHandle bridge);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_get_stats")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeRecorderResult GetStats(
            NativeBridgeHandle bridge,
            ref NativeStats stats);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_get_last_error")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial IntPtr GetLastError(NativeBridgeHandle bridge);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_version")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial IntPtr Version();

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_enumerate_endpoints")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeRecorderResult EnumerateEndpoints(
            NativeBridgeHandle bridge,
            out IntPtr endpointList);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_probe_teams_render_endpoints")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeRecorderResult ProbeTeamsRenderEndpoints(
            NativeBridgeHandle bridge,
            out IntPtr endpointList);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_endpoint_list_destroy")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial void DestroyEndpointList(IntPtr endpointList);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_endpoint_list_get_count")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeRecorderResult GetEndpointCount(
            NativeEndpointListHandle endpointList,
            out uint count);

        [LibraryImport(LibraryName, EntryPoint = "recorder_native_endpoint_list_get")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeRecorderResult GetEndpoint(
            NativeEndpointListHandle endpointList,
            uint index,
            out CaptureEndpointFlow flow,
            out uint defaultRoles,
            out IntPtr endpointIdUtf8,
            out IntPtr friendlyNameUtf8);
    }
}
