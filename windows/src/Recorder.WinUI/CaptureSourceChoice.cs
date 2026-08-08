using Recorder.Core;
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
        "系統音訊（建議）",
        "建議的 Teams 錄音來源：透過系統 loopback 錄製目前輸出裝置播放的音訊，可靠包含參與者音訊。");

    /// <summary>
    /// System render loopback is the reliable default for Teams meetings: it
    /// includes the audio heard by the local participant.
    /// </summary>
    public static CaptureSourceChoice Default { get; } = SystemAudio;

    public static CaptureSourceChoice SelectedApplication { get; } = new(
        CaptureSourceKind.SelectedApplication,
        "指定應用程式（Preview／實驗性）",
        "Preview／實驗性：只錄製所選 Teams 程序及其子處理程序的音訊，可能無法包含所有參與者音訊；若程序不可用，錄音會失敗且不會回退至系統音訊。");

    /// <summary>
    /// A cleared picker value must preserve the user's current choice. In
    /// particular, it must not turn an explicit process-loopback choice into
    /// an unannounced system-loopback session.
    /// </summary>
    public static CaptureSourceChoice ResolveSelection(
        CaptureSourceChoice? requested,
        CaptureSourceChoice? current) => requested ?? current ?? Default;
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

/// <summary>Presentation-only wrapper for an admitted exact Teams HWND.</summary>
public sealed record VideoCaptureWindowChoice(VideoCaptureTarget Target)
{
    public string DisplayName => string.IsNullOrWhiteSpace(Target.WindowTitle)
        ? Target.ProcessName
        : Target.WindowTitle;
    public string Description => $"{Target.ProcessName} — selected Teams window";
}
