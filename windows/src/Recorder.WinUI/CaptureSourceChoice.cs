using TeamsRecorder.Windows.Application;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// The capture scope selected in the WinUI surface. Native capture and process
/// validation remain owned by the application layer.
/// </summary>
public enum CaptureSourceKind
{
    SystemAudio,
    SelectedApplication,
}

public sealed record CaptureSourceChoice(
    CaptureSourceKind Kind,
    string DisplayName,
    string Description)
{
    public static CaptureSourceChoice SystemAudio { get; } = new(
        CaptureSourceKind.SystemAudio,
        "系統音訊",
        "錄製目前所選輸出裝置播放的系統音訊。");

    public static CaptureSourceChoice SelectedApplication { get; } = new(
        CaptureSourceKind.SelectedApplication,
        "指定應用程式",
        "只錄製所選應用程式及其子處理程序的音訊。");
}

/// <summary>
/// A non-sensitive presentation record. PID plus process start time is the
/// selection identity; a PID reuse must never preserve an old selection.
/// </summary>
public sealed record ProcessSelectionChoice(
    uint ProcessId,
    DateTimeOffset StartedAtUtc,
    string ApplicationName,
    string ProcessName,
    string? WindowTitle,
    bool HasWindow,
    ProcessCatalogAvailability Availability)
{
    public string DisplayName => string.IsNullOrWhiteSpace(ApplicationName)
        ? ProcessName
        : ApplicationName;

    public string? WindowDescription => string.IsNullOrWhiteSpace(WindowTitle)
        ? null
        : $"Window: {WindowTitle}";

    // Process loopback is PID-based, so valid background/console processes are
    // selectable too. Windowed applications are merely sorted first by the
    // catalog for a friendlier picker.
    public bool IsAvailable => Availability == ProcessCatalogAvailability.Available;

    public string ProcessDescription => $"{ProcessName} · PID {ProcessId}";

    public string WindowAvailabilityText => HasWindow
        ? "可使用的視窗"
        : "沒有頂層視窗（仍可選取）";

    public bool HasSameIdentity(ProcessSelectionChoice? other) =>
        other is not null &&
        ProcessId == other.ProcessId &&
        StartedAtUtc == other.StartedAtUtc;
}
