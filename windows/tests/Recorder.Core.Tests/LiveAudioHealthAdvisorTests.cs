using TeamsRecorder.Windows.Application;

internal static class LiveAudioHealthAdvisorTests
{
    public static void ReportsNeutralBeforeCaptureAndHealthySignalsDuringCapture()
    {
        var before = LiveAudioHealthAdvisor.Assess(
            NativeCaptureStats.Empty(RecordingCaptureMode.Mixed),
            isCaptureActive: false,
            primaryTitle: "系統音訊",
            primaryAvailable: true,
            microphoneIncluded: true,
            microphoneAvailable: true,
            microphoneMuted: false);
        Equal(LiveAudioHealthStatus.Neutral, before.Primary.Status);
        Equal(LiveAudioHealthStatus.Neutral, before.Microphone.Status);

        var active = LiveAudioHealthAdvisor.Assess(
            NativeCaptureStats.Empty(RecordingCaptureMode.Mixed) with
            {
                Packets = 2,
                SilentPackets = 0,
                PrimaryLevelPeak = 0.2f,
                PrimaryLevelRms = 0.1f,
                MicrophoneLevelPeak = 0.2f,
                MicrophoneLevelRms = 0.1f,
            },
            isCaptureActive: true,
            primaryTitle: "系統音訊",
            primaryAvailable: true,
            microphoneIncluded: true,
            microphoneAvailable: true,
            microphoneMuted: false);
        Equal(LiveAudioHealthStatus.Healthy, active.Primary.Status);
        Equal(LiveAudioHealthStatus.Healthy, active.Microphone.Status);
    }

    public static void WarnsOnSilentOrDisconnectedInputsButKeepsMutedMicNeutral()
    {
        var silent = LiveAudioHealthAdvisor.Assess(
            NativeCaptureStats.Empty(RecordingCaptureMode.Mixed) with { Packets = 3, SilentPackets = 3 },
            isCaptureActive: true,
            primaryTitle: "系統音訊",
            primaryAvailable: true,
            microphoneIncluded: true,
            microphoneAvailable: true,
            microphoneMuted: true);
        Equal(LiveAudioHealthStatus.Warning, silent.Primary.Status);
        Equal(LiveAudioHealthStatus.Neutral, silent.Microphone.Status);

        var disconnected = LiveAudioHealthAdvisor.Assess(
            NativeCaptureStats.Empty(RecordingCaptureMode.Mixed) with
            {
                Packets = 1,
                PrimaryLevelRms = 0.1f,
                MicrophoneTimeline = NativeSourceTimelineStats.Empty with { SourceDisconnects = 1 },
            },
            isCaptureActive: true,
            primaryTitle: "系統音訊",
            primaryAvailable: true,
            microphoneIncluded: true,
            microphoneAvailable: true,
            microphoneMuted: false);
        Equal(LiveAudioHealthStatus.Warning, disconnected.Microphone.Status);

        var unavailable = LiveAudioHealthAdvisor.Assess(
            NativeCaptureStats.Empty(RecordingCaptureMode.Mixed),
            isCaptureActive: false,
            primaryTitle: "系統音訊",
            primaryAvailable: false,
            microphoneIncluded: false,
            microphoneAvailable: true,
            microphoneMuted: false);
        Equal(LiveAudioHealthStatus.Warning, unavailable.Primary.Status);
    }

    private static void Equal<T>(T expected, T actual) where T : notnull
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected {expected}; got {actual}.");
        }
    }
}
