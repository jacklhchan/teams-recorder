using System.Text.Json.Nodes;
using Recorder.Core;

internal static class MetadataPrivacyTests
{
    public static void WindowsCaptureMetadataRoundTripsTheApprovedEnvelope()
    {
        var initial = RecordingInfoJson.CreateAudioOnly(
            null,
            "Process capture",
            RecordingRecoveryState.None,
            RecordingSessionKind.Meeting);
        var capture = WindowsCaptureMetadata.ForSelectedProcessLoopback("Teams.exe");

        var withCapture = RecordingInfoJson.WithWindowsCapture(initial, capture);
        var roundTripped = RecordingInfoJson.Parse(withCapture.Document.ToJsonString());

        Equal(capture, roundTripped.WindowsCapture!);
        Equal("teamsAutomatic", roundTripped.Source);
        Equal("audio", roundTripped.MediaKind);
    }

    public static void MetadataPrivacyDropsTransientProcessIdentifiers()
    {
        var parsed = RecordingInfoJson.Parse("""
            {
              "mediaKind":"audio",
              "windowsCapture":{
                "audioSource":"selectedProcessLoopback",
                "processName":"Teams.exe",
                "includedProcessTree":false,
                "processId":711,
                "executablePath":"C:\\private\\Teams.exe",
                "commandLine":"Teams.exe --token secret",
                "token":"secret"
              }
            }
            """);

        var capture = parsed.WindowsCapture
            ?? throw new InvalidOperationException("The approved capture envelope was unexpectedly removed.");
        Equal(WindowsCaptureMetadata.SelectedProcessLoopback, capture.AudioSource);
        Equal("Teams.exe", capture.ProcessName!);
        if (!capture.IncludedProcessTree)
        {
            throw new InvalidOperationException("Selected process metadata must retain the capture-tree meaning.");
        }

        var document = parsed.Document["windowsCapture"] as JsonObject
            ?? throw new InvalidOperationException("The capture envelope was not normalized.");
        if (document["processId"] is not null || document["executablePath"] is not null ||
            document["commandLine"] is not null || document["token"] is not null)
        {
            throw new InvalidOperationException("Transient process identity leaked into persisted metadata.");
        }
    }

    public static void ExecutableBasenamesSupportOrdinarySpacesAndUnicodeWithoutDroppingProvenance()
    {
        foreach (var name in new[] { "My Meeting App.exe", "會議助手.exe", "ms-teams.exe" })
        {
            var capture = WindowsCaptureMetadata.ForSelectedProcessLoopback(name);
            var info = RecordingInfoJson.WithWindowsCapture(RecordingInfo.AudioOnly(), capture);
            var roundTripped = RecordingInfoJson.Parse(info.Document.ToJsonString());
            Equal(name, roundTripped.WindowsCapture?.ProcessName!);
        }

        foreach (var invalid in new[] { "C:\\private\\Teams.exe", "bad<name>.exe", "bad\u0001name.exe", "trailing.exe " })
        {
            Throws<ArgumentException>(() => WindowsCaptureMetadata.ForSelectedProcessLoopback(invalid));
        }

        Throws<ArgumentException>(() => RecordingInfoJson.WithWindowsCapture(
            RecordingInfo.AudioOnly(),
            new WindowsCaptureMetadata(
                WindowsCaptureMetadata.SelectedProcessLoopback,
                "bad<name>.exe",
                true,
                null)));
    }

    private static void Equal<T>(T expected, T actual) where T : notnull
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
}
