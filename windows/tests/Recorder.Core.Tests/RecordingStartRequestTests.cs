using Recorder.Core;
using TeamsRecorder.Windows.Application;

internal static class RecordingStartRequestTests
{
    public static void ValidatesSystemAndSelectedProcessWithOptionalMicrophone()
    {
        new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SystemLoopback,
            RenderEndpointId: "render-default",
            MicrophoneEndpointId: "capture-usb").Validate();

        new RecordingStartRequest(
            RecordingSessionKind.Meeting,
            RecordingAudioSource.SelectedProcessLoopback,
            MicrophoneEndpointId: "capture-usb",
            ProcessTarget: Target(71, "ms-teams"),
            IncludeProcessTree: true).Validate();

        new RecordingStartRequest(
            RecordingSessionKind.Test,
            RecordingAudioSource.SystemLoopback,
            TestDuration: TimeSpan.FromSeconds(10)).Validate();
    }

    public static void RejectsAmbiguousOrIncompatibleSelections()
    {
        Throws<ArgumentException>(() => new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SystemLoopback,
            RenderEndpointId: " ").Validate());
        Throws<ArgumentException>(() => new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SystemLoopback,
            ProcessTarget: Target(71, "ms-teams")).Validate());
        Throws<ArgumentException>(() => new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SelectedProcessLoopback,
            ProcessTarget: Target(71, "ms-teams")).Validate());
        Throws<ArgumentException>(() => new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SelectedProcessLoopback,
            RenderEndpointId: "render-default",
            ProcessTarget: Target(71, "ms-teams"),
            IncludeProcessTree: true).Validate());
        Throws<ArgumentOutOfRangeException>(() => new RecordingStartRequest(
            RecordingSessionKind.Test,
            RecordingAudioSource.SystemLoopback).Validate());
    }

    public static void SelectsProcessOnlyWhenItsFullIdentityIsCurrent()
    {
        var selected = Target(71, "ms-teams");
        var catalog = new FakeProcessCatalog(Entry(selected));
        var policy = new CaptureSourceSelectionPolicy(catalog);
        var request = new RecordingStartRequest(
            RecordingSessionKind.Meeting,
            RecordingAudioSource.SelectedProcessLoopback,
            MicrophoneEndpointId: "capture-usb",
            ProcessTarget: selected,
            IncludeProcessTree: true);

        var native = policy.CreateSelectedAudioRequest(request, "C:\\recordings\\meeting.m4a");
        Equal(NativeSelectedAudioSource.ProcessTreeLoopback, native.AudioSource);
        Equal(RecordingCaptureMode.SelectedAppMixed, native.Mode);
        Equal(selected.ProcessId, native.TargetProcessId);
        Equal(true, native.IncludedProcessTree);
        Equal(checked((ulong)selected.StartedAt.UtcDateTime.ToFileTimeUtc()), native.ExpectedProcessCreationTime100Nanoseconds);
        Equal(null, native.RenderEndpointId);
        Equal("capture-usb", native.MicrophoneEndpointId!);
    }

    public static void RejectsPidReuseRatherThanCapturingTheWrongProcess()
    {
        var selected = Target(71, "ms-teams");
        var reusedPid = Entry(selected) with { StartedAt = selected.StartedAt.AddSeconds(1) };
        var policy = new CaptureSourceSelectionPolicy(new FakeProcessCatalog(reusedPid));
        var request = new RecordingStartRequest(
            RecordingSessionKind.Meeting,
            RecordingAudioSource.SelectedProcessLoopback,
            ProcessTarget: selected,
            IncludeProcessTree: true);

        Throws<InvalidOperationException>(() => policy.CreateSelectedAudioRequest(request, "C:\\recordings\\meeting.m4a"));
    }

    public static void DoesNotFallbackWhenSelectedProcessIsUnavailable()
    {
        var selected = Target(71, "ms-teams");
        var policy = new CaptureSourceSelectionPolicy(new FakeProcessCatalog());
        var request = new RecordingStartRequest(
            RecordingSessionKind.Meeting,
            RecordingAudioSource.SelectedProcessLoopback,
            ProcessTarget: selected,
            IncludeProcessTree: true);

        Throws<InvalidOperationException>(() => policy.CreateSelectedAudioRequest(request, "C:\\recordings\\meeting.m4a"));
    }

    public static void MapsSystemAndMicrophoneWithoutInventingEndpoints()
    {
        var policy = new CaptureSourceSelectionPolicy();
        var system = policy.CreateSelectedAudioRequest(
            new RecordingStartRequest(
                RecordingSessionKind.Manual,
                RecordingAudioSource.SystemLoopback,
                MicrophoneEndpointId: "capture-usb"),
            "C:\\recordings\\system.m4a");
        Equal(NativeSelectedAudioSource.SystemLoopback, system.AudioSource);
        Equal(null, system.RenderEndpointId);
        Equal("capture-usb", system.MicrophoneEndpointId!);

        var metadata = RecordingStartMetadataPolicy.CreateWindowsCaptureMetadata(new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SelectedProcessLoopback,
            ProcessTarget: Target(71, "ms-teams"),
            IncludeProcessTree: true));
        Equal("ms-teams.exe", metadata.ProcessName!);
    }

    public static void MapsSystemRenderEndpointThroughTheLegacyNativeRequest()
    {
        var request = new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SystemLoopback,
            RenderEndpointId: "render-headset");

        var native = new CaptureSourceSelectionPolicy().CreateNativeRequest(request, "C:\\recordings\\system.wav");
        Equal(RecordingCaptureMode.SystemLoopback, native.Mode);
        Equal("render-headset", native.EndpointId!);
        Equal(0U, native.TargetProcessId);
    }

    public static void UsesOneExecutableBasenamePolicyForProcessTargetsAndMetadata()
    {
        foreach (var name in new[] { "My Meeting App", "會議助手", "normal-app" })
        {
            var target = Target(71, name);
            target.Validate();
            var metadata = RecordingStartMetadataPolicy.CreateWindowsCaptureMetadata(new RecordingStartRequest(
                RecordingSessionKind.Manual,
                RecordingAudioSource.SelectedProcessLoopback,
                ProcessTarget: target,
                IncludeProcessTree: true));
            Equal(name + ".exe", metadata.ProcessName!);
        }

        foreach (var invalid in new[] { "C:\\private\\app", "reserved|name", "control\u0001name", "trailing " })
        {
            Throws<ArgumentException>(() => Target(71, invalid).Validate());
        }
    }

    private static SelectedProcessTarget Target(uint pid, string processName) => new(
        pid,
        new DateTimeOffset(2026, 7, 30, 5, 0, 0, TimeSpan.Zero),
        processName);

    private static ProcessCatalogEntry Entry(SelectedProcessTarget target) => new(
        target.ProcessId,
        target.StartedAt,
        target.ProcessName)
    {
        ApplicationName = target.ProcessName,
        ProcessName = target.ProcessName,
        HasWindow = true,
        Availability = ProcessCatalogAvailability.Available,
    };

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}; got {actual}.");
    }

    private static void Throws<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }

    private sealed class FakeProcessCatalog(params ProcessCatalogEntry[] processes) : IProcessCatalog
    {
        private readonly IReadOnlyList<ProcessCatalogEntry> entries = processes;

        public IReadOnlyList<ProcessCatalogEntry> GetProcesses() => entries;

        public bool IsCurrent(SelectedProcessTarget target) => entries.Any(entry =>
            entry.ProcessId == target.ProcessId &&
            entry.StartedAt == target.StartedAt &&
            entry.Availability == ProcessCatalogAvailability.Available &&
            string.Equals(entry.ProcessName, target.ProcessName, StringComparison.Ordinal));
    }
}
