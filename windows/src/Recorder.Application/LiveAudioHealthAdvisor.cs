namespace TeamsRecorder.Windows.Application;

/// <summary>Presentation-neutral severity for the live audio health indicators.</summary>
public enum LiveAudioHealthStatus { Healthy, Warning, Neutral }

/// <summary>One input's human-readable health state without exposing device identifiers.</summary>
public sealed record LiveAudioHealthIndicator(string Title, string Detail, LiveAudioHealthStatus Status);

/// <summary>macOS-parity live health assessment for the primary capture source and optional microphone.</summary>
public sealed record LiveAudioHealthAssessment(
    LiveAudioHealthIndicator Primary,
    LiveAudioHealthIndicator Microphone)
{
    public string Summary => Primary.Status is LiveAudioHealthStatus.Warning || Microphone.Status is LiveAudioHealthStatus.Warning
        ? "健康檢查發現需要注意的音訊來源。"
        : Primary.Status is LiveAudioHealthStatus.Healthy || Microphone.Status is LiveAudioHealthStatus.Healthy
            ? "健康檢查正常：已偵測到可用的音訊訊號。"
            : "尚未開始錄音；可使用 10 秒測試確認裝置與訊號。";
}

/// <summary>
/// Converts bounded native level/timeline telemetry into the same three-state
/// health language used by macOS. It never probes a device or changes capture.
/// </summary>
public static class LiveAudioHealthAdvisor
{
    private const float SilenceThreshold = 0.0001f;
    private const float ClippingThreshold = 0.99f;

    public static LiveAudioHealthAssessment Assess(
        NativeCaptureStats stats,
        bool isCaptureActive,
        string primaryTitle,
        bool primaryAvailable,
        bool microphoneIncluded,
        bool microphoneAvailable,
        bool microphoneMuted)
    {
        ArgumentNullException.ThrowIfNull(primaryTitle);
        return new(
            AssessPrimary(stats, isCaptureActive, primaryTitle, primaryAvailable),
            AssessMicrophone(stats, isCaptureActive, microphoneIncluded, microphoneAvailable, microphoneMuted));
    }

    private static LiveAudioHealthIndicator AssessPrimary(
        NativeCaptureStats stats,
        bool isCaptureActive,
        string title,
        bool available)
    {
        if (!available)
        {
            return new(title, "裝置已中斷。", LiveAudioHealthStatus.Warning);
        }
        if (!isCaptureActive)
        {
            return new(title, "尚未開始錄音；可用 10 秒測試確認。", LiveAudioHealthStatus.Neutral);
        }
        if (stats.Packets == 0)
        {
            return new(title, "尚未收到音訊封包。", LiveAudioHealthStatus.Warning);
        }
        if (stats.RenderTimeline.SourceDisconnects > 0)
        {
            return new(title, "音源曾中斷；缺失區段已保留為靜音。", LiveAudioHealthStatus.Warning);
        }
        if (stats.RenderTimeline.QueueOverflows > 0 || stats.Discontinuities > 0)
        {
            return new(title, "偵測到時間軸中斷或佇列溢位。", LiveAudioHealthStatus.Warning);
        }
        if (stats.Peak >= ClippingThreshold || stats.PrimaryLevelPeak >= ClippingThreshold)
        {
            return new(title, "訊號可能剪裁。", LiveAudioHealthStatus.Warning);
        }
        if (stats.SilentPackets == stats.Packets || stats.PrimaryLevelRms <= SilenceThreshold)
        {
            return new(title, "未偵測到訊號。", LiveAudioHealthStatus.Warning);
        }
        return new(title, "已偵測到訊號。", LiveAudioHealthStatus.Healthy);
    }

    private static LiveAudioHealthIndicator AssessMicrophone(
        NativeCaptureStats stats,
        bool isCaptureActive,
        bool included,
        bool available,
        bool muted)
    {
        const string title = "麥克風";
        if (!included)
        {
            return new(title, "未啟用（不錄製）。", LiveAudioHealthStatus.Neutral);
        }
        if (!available)
        {
            return new(title, "裝置已中斷。", LiveAudioHealthStatus.Warning);
        }
        if (muted)
        {
            return new(title, "錄音麥克風已靜音。", LiveAudioHealthStatus.Neutral);
        }
        if (!isCaptureActive)
        {
            return new(title, "尚未開始錄音；可用 10 秒測試確認。", LiveAudioHealthStatus.Neutral);
        }
        if (stats.MicrophoneTimeline.SourceDisconnects > 0)
        {
            return new(title, "音源曾中斷；缺失區段已保留為靜音。", LiveAudioHealthStatus.Warning);
        }
        if (stats.MicrophoneLevelPeak >= ClippingThreshold)
        {
            return new(title, "訊號可能剪裁。", LiveAudioHealthStatus.Warning);
        }
        if (stats.MicrophoneLevelRms <= SilenceThreshold)
        {
            return new(title, "未偵測到訊號。", LiveAudioHealthStatus.Warning);
        }
        return new(title, "已偵測到訊號。", LiveAudioHealthStatus.Healthy);
    }
}
